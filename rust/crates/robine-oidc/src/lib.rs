//! Standards-based `OpenID` Connect adapter with server-owned transient flow state.

use std::{collections::HashMap, time::Instant};

use async_trait::async_trait;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use openidconnect::{
    AuthorizationCode, ClientId, ClientSecret, CsrfToken, IssuerUrl, Nonce, PkceCodeChallenge,
    PkceCodeVerifier, RedirectUrl, Scope, TokenResponse,
    core::{CoreAuthenticationFlow, CoreClient, CoreProviderMetadata},
    reqwest,
};
use robine_core::{
    identity::{OidcAuthorization, OidcClaims},
    ports::{OidcProvider, PortError},
};
use tokio::sync::Mutex;

pub struct OidcClient {
    metadata: CoreProviderMetadata,
    client_id: String,
    client_secret: String,
    redirect_uri: String,
    http: reqwest::Client,
    pending: Mutex<HashMap<String, PendingFlow>>,
}

struct PendingFlow {
    nonce: String,
    verifier: String,
    created_at: Instant,
}

impl OidcClient {
    /// Discovers and validates provider metadata without following redirects.
    ///
    /// # Errors
    ///
    /// Returns [`PortError::Unavailable`] for invalid configuration or failed discovery.
    pub async fn discover(
        issuer: &str,
        client_id: String,
        client_secret: String,
        redirect_uri: String,
    ) -> Result<Self, PortError> {
        let http = reqwest::ClientBuilder::new()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| PortError::Unavailable)?;
        let issuer = IssuerUrl::new(issuer.into()).map_err(|_| PortError::InvalidData)?;
        let metadata = CoreProviderMetadata::discover_async(issuer, &http)
            .await
            .map_err(|_| PortError::Unavailable)?;
        Ok(Self {
            metadata,
            client_id,
            client_secret,
            redirect_uri,
            http,
            pending: Mutex::new(HashMap::new()),
        })
    }
}

#[async_trait]
impl OidcProvider for OidcClient {
    async fn start(&self) -> Result<OidcAuthorization, PortError> {
        let client = CoreClient::from_provider_metadata(
            self.metadata.clone(),
            ClientId::new(self.client_id.clone()),
            Some(ClientSecret::new(self.client_secret.clone())),
        )
        .set_redirect_uri(
            RedirectUrl::new(self.redirect_uri.clone()).map_err(|_| PortError::InvalidData)?,
        );
        let (challenge, verifier) = PkceCodeChallenge::new_random_sha256();
        let state_secret = random_secret()?;
        let nonce_secret = random_secret()?;
        let (url, state, nonce) = client
            .authorize_url(
                CoreAuthenticationFlow::AuthorizationCode,
                move || CsrfToken::new(state_secret),
                move || Nonce::new(nonce_secret),
            )
            .add_scope(Scope::new("email".into()))
            .add_scope(Scope::new("profile".into()))
            .set_pkce_challenge(challenge)
            .url();

        let state_value = state.secret().clone();
        let mut pending = self.pending.lock().await;
        pending.retain(|_, flow| flow.created_at.elapsed().as_secs() < 600);
        pending.insert(
            state_value.clone(),
            PendingFlow {
                nonce: nonce.secret().clone(),
                verifier: verifier.secret().clone(),
                created_at: Instant::now(),
            },
        );
        Ok(OidcAuthorization {
            url: url.to_string(),
            state: state_value,
        })
    }

    async fn complete(&self, code: &str, state: &str) -> Result<OidcClaims, PortError> {
        let pending = self
            .pending
            .lock()
            .await
            .remove(state)
            .ok_or(PortError::InvalidData)?;
        if pending.created_at.elapsed().as_secs() >= 600 {
            return Err(PortError::InvalidData);
        }

        let client = CoreClient::from_provider_metadata(
            self.metadata.clone(),
            ClientId::new(self.client_id.clone()),
            Some(ClientSecret::new(self.client_secret.clone())),
        )
        .set_redirect_uri(
            RedirectUrl::new(self.redirect_uri.clone()).map_err(|_| PortError::InvalidData)?,
        );
        let token_response = client
            .exchange_code(AuthorizationCode::new(code.into()))
            .map_err(|_| PortError::InvalidData)?
            .set_pkce_verifier(PkceCodeVerifier::new(pending.verifier))
            .request_async(&self.http)
            .await
            .map_err(|_| PortError::Unavailable)?;
        let id_token = token_response.id_token().ok_or(PortError::InvalidData)?;
        let claims = id_token
            .claims(&client.id_token_verifier(), &Nonce::new(pending.nonce))
            .map_err(|_| PortError::InvalidData)?;
        let email = claims.email().ok_or(PortError::InvalidData)?;

        Ok(OidcClaims {
            issuer: claims.issuer().to_string(),
            subject: claims.subject().to_string(),
            email: email.to_string(),
            email_verified: claims.email_verified().unwrap_or(false),
        })
    }
}

fn random_secret() -> Result<String, PortError> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(|_| PortError::Unavailable)?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

#[cfg(test)]
mod tests {
    use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
    use robine_core::ports::OidcProvider;
    use serde_json::json;
    use url::Url;
    use wiremock::{
        Mock, MockServer, ResponseTemplate,
        matchers::{body_string_contains, method, path},
    };

    use super::*;

    #[tokio::test]
    async fn discovery_and_authorization_use_state_nonce_and_s256_pkce() {
        let server = MockServer::start().await;
        let issuer = server.uri();
        Mock::given(method("GET"))
            .and(path("/.well-known/openid-configuration"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "issuer": issuer,
                "authorization_endpoint": format!("{issuer}/authorize"),
                "token_endpoint": format!("{issuer}/token"),
                "jwks_uri": format!("{issuer}/jwks"),
                "response_types_supported": ["code"],
                "subject_types_supported": ["public"],
                "id_token_signing_alg_values_supported": ["HS256"]
            })))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/jwks"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"keys": []})))
            .mount(&server)
            .await;

        let client = OidcClient::discover(
            &issuer,
            "client".into(),
            "secret".into(),
            "https://robine.example/auth/oidc/callback".into(),
        )
        .await
        .expect("discover provider");
        let authorization = client.start().await.expect("start authorization");
        let url = Url::parse(&authorization.url).expect("authorization URL");
        let query = url.query_pairs().collect::<HashMap<_, _>>();

        assert_eq!(
            query.get("response_type").map(std::convert::AsRef::as_ref),
            Some("code")
        );
        assert_eq!(
            query
                .get("code_challenge_method")
                .map(std::convert::AsRef::as_ref),
            Some("S256")
        );
        assert_eq!(
            query.get("state").map(std::convert::AsRef::as_ref),
            Some(authorization.state.as_str())
        );
        assert!(query.get("nonce").is_some_and(|value| value.len() >= 32));
        assert!(query.contains_key("code_challenge"));
        assert!(!query.contains_key("code_verifier"));

        let nonce = query.get("nonce").expect("nonce").to_string();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("time after epoch")
            .as_secs();
        let id_token = encode(
            &Header::new(Algorithm::HS256),
            &json!({
                "iss": issuer,
                "sub": "subject-1",
                "aud": "client",
                "exp": now + 300,
                "iat": now,
                "nonce": nonce,
                "email": "dev@example.com",
                "email_verified": true
            }),
            &EncodingKey::from_secret(b"secret"),
        )
        .expect("sign test ID token");
        Mock::given(method("POST"))
            .and(path("/token"))
            .and(body_string_contains("code=valid-code"))
            .and(body_string_contains("code_verifier="))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "access_token": "access-token",
                "token_type": "Bearer",
                "id_token": id_token
            })))
            .mount(&server)
            .await;

        let claims = client
            .complete("valid-code", &authorization.state)
            .await
            .expect("validate callback");
        assert_eq!(claims.issuer, issuer);
        assert_eq!(claims.subject, "subject-1");
        assert_eq!(claims.email, "dev@example.com");
        assert!(claims.email_verified);

        let replay = client.complete("valid-code", &authorization.state).await;
        assert!(matches!(replay, Err(PortError::InvalidData)));
    }
}
