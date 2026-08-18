use std::sync::Arc;

use actix_web::{HttpRequest, HttpResponse, Responder, web};
use robine_application::{ApplicationError, ControlPlane};
use robine_core::identity::Role;
use robine_persistence::Readiness;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone)]
pub struct AppState {
    readiness: Arc<dyn Readiness>,
    control_plane: Arc<ControlPlane>,
}

impl AppState {
    #[must_use]
    pub fn new(readiness: Arc<dyn Readiness>, control_plane: Arc<ControlPlane>) -> Self {
        Self {
            readiness,
            control_plane,
        }
    }
}

#[derive(Serialize)]
struct HealthResponse {
    status: &'static str,
}

async fn live() -> impl Responder {
    web::Json(HealthResponse { status: "ok" })
}

async fn ready(state: web::Data<AppState>) -> impl Responder {
    match state.readiness.ready().await {
        Ok(()) => HttpResponse::Ok().json(HealthResponse { status: "ready" }),
        Err(_) => HttpResponse::ServiceUnavailable().json(HealthResponse {
            status: "not_ready",
        }),
    }
}

async fn not_found() -> impl Responder {
    HttpResponse::NotFound().finish()
}

#[derive(Deserialize)]
struct PipelineQuery {
    repository_id: Option<Uuid>,
    limit: Option<i64>,
}

async fn list_pipelines(
    request: HttpRequest,
    query: web::Query<PipelineQuery>,
    state: web::Data<AppState>,
) -> impl Responder {
    let Some(token) = bearer_token(&request) else {
        return HttpResponse::Unauthorized().finish();
    };

    let user = match state.control_plane.authenticate(token).await {
        Ok(user) => user,
        Err(ApplicationError::InvalidCredentials | ApplicationError::Unauthenticated) => {
            return HttpResponse::Unauthorized().finish();
        }
        Err(ApplicationError::Forbidden) => return HttpResponse::Forbidden().finish(),
        Err(
            ApplicationError::AlreadyBootstrapped
            | ApplicationError::BootstrapTokenExpired
            | ApplicationError::InvalidBootstrapToken
            | ApplicationError::InvalidEmail
            | ApplicationError::LastAdministrator
            | ApplicationError::InvalidOidcIdentity
            | ApplicationError::OidcEmailCollision
            | ApplicationError::OidcNotConfigured
            | ApplicationError::OidcProtocol
            | ApplicationError::PipelineNotCancellable
            | ApplicationError::PipelineNotFound
            | ApplicationError::Unavailable
            | ApplicationError::WeakPassword,
        ) => return HttpResponse::ServiceUnavailable().finish(),
    };

    match state
        .control_plane
        .list_pipelines(&user, query.repository_id, query.limit.unwrap_or(50))
        .await
    {
        Ok(pipelines) => HttpResponse::Ok().json(pipelines),
        Err(ApplicationError::InvalidCredentials | ApplicationError::Unauthenticated) => {
            HttpResponse::Unauthorized().finish()
        }
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(
            ApplicationError::AlreadyBootstrapped
            | ApplicationError::BootstrapTokenExpired
            | ApplicationError::InvalidBootstrapToken
            | ApplicationError::InvalidEmail
            | ApplicationError::LastAdministrator
            | ApplicationError::InvalidOidcIdentity
            | ApplicationError::OidcEmailCollision
            | ApplicationError::OidcNotConfigured
            | ApplicationError::OidcProtocol
            | ApplicationError::PipelineNotCancellable
            | ApplicationError::PipelineNotFound
            | ApplicationError::Unavailable
            | ApplicationError::WeakPassword,
        ) => HttpResponse::ServiceUnavailable().finish(),
    }
}

async fn cancel_pipeline(
    request: HttpRequest,
    pipeline_id: web::Path<Uuid>,
    state: web::Data<AppState>,
) -> impl Responder {
    let Some(token) = bearer_token(&request) else {
        return HttpResponse::Unauthorized().finish();
    };
    let user = match state.control_plane.authenticate(token).await {
        Ok(user) => user,
        Err(ApplicationError::InvalidCredentials | ApplicationError::Unauthenticated) => {
            return HttpResponse::Unauthorized().finish();
        }
        Err(_) => return HttpResponse::ServiceUnavailable().finish(),
    };

    match state
        .control_plane
        .cancel_pipeline(&user, pipeline_id.into_inner())
        .await
    {
        Ok(pipeline) => HttpResponse::Ok().json(pipeline),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(ApplicationError::PipelineNotFound) => HttpResponse::NotFound().finish(),
        Err(ApplicationError::PipelineNotCancellable) => HttpResponse::Conflict().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

#[derive(Deserialize)]
struct SignInRequest {
    email: String,
    password: String,
}

async fn sign_in(input: web::Json<SignInRequest>, state: web::Data<AppState>) -> impl Responder {
    match state
        .control_plane
        .authenticate_local(&input.email, &input.password)
        .await
    {
        Ok(session) => HttpResponse::Ok().json(session),
        Err(ApplicationError::InvalidCredentials | ApplicationError::Unauthenticated) => {
            HttpResponse::Unauthorized().finish()
        }
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(
            ApplicationError::AlreadyBootstrapped
            | ApplicationError::BootstrapTokenExpired
            | ApplicationError::InvalidBootstrapToken
            | ApplicationError::InvalidEmail
            | ApplicationError::LastAdministrator
            | ApplicationError::InvalidOidcIdentity
            | ApplicationError::OidcEmailCollision
            | ApplicationError::OidcNotConfigured
            | ApplicationError::OidcProtocol
            | ApplicationError::PipelineNotCancellable
            | ApplicationError::PipelineNotFound
            | ApplicationError::Unavailable
            | ApplicationError::WeakPassword,
        ) => HttpResponse::ServiceUnavailable().finish(),
    }
}

async fn sign_out(request: HttpRequest, state: web::Data<AppState>) -> impl Responder {
    let Some(token) = bearer_token(&request) else {
        return HttpResponse::NoContent().finish();
    };

    match state.control_plane.revoke_session(token).await {
        Ok(()) | Err(ApplicationError::Unauthenticated | ApplicationError::InvalidCredentials) => {
            HttpResponse::NoContent().finish()
        }
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(
            ApplicationError::AlreadyBootstrapped
            | ApplicationError::BootstrapTokenExpired
            | ApplicationError::InvalidBootstrapToken
            | ApplicationError::InvalidEmail
            | ApplicationError::LastAdministrator
            | ApplicationError::InvalidOidcIdentity
            | ApplicationError::OidcEmailCollision
            | ApplicationError::OidcNotConfigured
            | ApplicationError::OidcProtocol
            | ApplicationError::PipelineNotCancellable
            | ApplicationError::PipelineNotFound
            | ApplicationError::Unavailable
            | ApplicationError::WeakPassword,
        ) => HttpResponse::ServiceUnavailable().finish(),
    }
}

async fn start_oidc(state: web::Data<AppState>) -> impl Responder {
    match state.control_plane.start_oidc().await {
        Ok(authorization) => HttpResponse::Found()
            .insert_header(("location", authorization.url))
            .finish(),
        Err(ApplicationError::OidcNotConfigured) => HttpResponse::NotFound().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

#[derive(Deserialize)]
struct OidcCallbackQuery {
    code: String,
    state: String,
}

async fn complete_oidc(
    query: web::Query<OidcCallbackQuery>,
    state: web::Data<AppState>,
) -> impl Responder {
    match state
        .control_plane
        .complete_oidc(&query.code, &query.state)
        .await
    {
        Ok(session) => HttpResponse::Ok().json(session),
        Err(ApplicationError::OidcEmailCollision) => HttpResponse::Conflict().finish(),
        Err(
            ApplicationError::InvalidOidcIdentity
            | ApplicationError::OidcProtocol
            | ApplicationError::Unauthenticated,
        ) => HttpResponse::Unauthorized().finish(),
        Err(ApplicationError::OidcNotConfigured) => HttpResponse::NotFound().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

#[derive(Deserialize)]
struct BootstrapRequest {
    token: String,
    email: String,
    password: String,
}

async fn bootstrap(
    input: web::Json<BootstrapRequest>,
    state: web::Data<AppState>,
) -> impl Responder {
    match state
        .control_plane
        .bootstrap_administrator(&input.token, &input.email, &input.password)
        .await
    {
        Ok(_) => match state
            .control_plane
            .authenticate_local(&input.email, &input.password)
            .await
        {
            Ok(session) => HttpResponse::Created().json(session),
            Err(_) => HttpResponse::ServiceUnavailable().finish(),
        },
        Err(ApplicationError::InvalidBootstrapToken) => HttpResponse::Unauthorized().finish(),
        Err(ApplicationError::BootstrapTokenExpired) => HttpResponse::Gone().finish(),
        Err(ApplicationError::AlreadyBootstrapped | ApplicationError::LastAdministrator) => {
            HttpResponse::Conflict().finish()
        }
        Err(ApplicationError::InvalidEmail | ApplicationError::WeakPassword) => {
            HttpResponse::UnprocessableEntity().finish()
        }
        Err(ApplicationError::InvalidCredentials | ApplicationError::Unauthenticated) => {
            HttpResponse::Unauthorized().finish()
        }
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(
            ApplicationError::InvalidOidcIdentity
            | ApplicationError::OidcEmailCollision
            | ApplicationError::OidcNotConfigured
            | ApplicationError::OidcProtocol
            | ApplicationError::PipelineNotCancellable
            | ApplicationError::PipelineNotFound
            | ApplicationError::Unavailable,
        ) => HttpResponse::ServiceUnavailable().finish(),
    }
}

async fn list_users(request: HttpRequest, state: web::Data<AppState>) -> impl Responder {
    let Some(token) = bearer_token(&request) else {
        return HttpResponse::Unauthorized().finish();
    };
    let actor = match state.control_plane.authenticate(token).await {
        Ok(actor) => actor,
        Err(ApplicationError::InvalidCredentials | ApplicationError::Unauthenticated) => {
            return HttpResponse::Unauthorized().finish();
        }
        Err(_) => return HttpResponse::ServiceUnavailable().finish(),
    };

    match state.control_plane.list_users(&actor).await {
        Ok(users) => HttpResponse::Ok().json(users),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

#[derive(Deserialize)]
struct ChangeRoleRequest {
    role: Role,
}

async fn change_user_role(
    request: HttpRequest,
    user_id: web::Path<Uuid>,
    input: web::Json<ChangeRoleRequest>,
    state: web::Data<AppState>,
) -> impl Responder {
    let Some(token) = bearer_token(&request) else {
        return HttpResponse::Unauthorized().finish();
    };
    let actor = match state.control_plane.authenticate(token).await {
        Ok(actor) => actor,
        Err(ApplicationError::InvalidCredentials | ApplicationError::Unauthenticated) => {
            return HttpResponse::Unauthorized().finish();
        }
        Err(_) => return HttpResponse::ServiceUnavailable().finish(),
    };

    match state
        .control_plane
        .change_user_role(&actor, user_id.into_inner(), input.role)
        .await
    {
        Ok(user) => HttpResponse::Ok().json(user),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(ApplicationError::LastAdministrator) => HttpResponse::Conflict().finish(),
        Err(ApplicationError::Unauthenticated) => HttpResponse::NotFound().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

fn bearer_token(request: &HttpRequest) -> Option<&str> {
    request
        .headers()
        .get("authorization")?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .filter(|token| !token.is_empty())
}

pub fn configure(config: &mut web::ServiceConfig) {
    config
        .route("/health/live", web::get().to(live))
        .route("/health/ready", web::get().to(ready))
        .route("/api/v1/auth/bootstrap", web::post().to(bootstrap))
        .route("/api/v1/auth/sign-in", web::post().to(sign_in))
        .route("/api/v1/auth/sign-out", web::delete().to(sign_out))
        .route("/api/v1/auth/oidc", web::get().to(start_oidc))
        .route("/api/v1/auth/oidc/callback", web::get().to(complete_oidc))
        .route("/auth/oidc", web::get().to(start_oidc))
        .route("/auth/oidc/callback", web::get().to(complete_oidc))
        .route("/api/v1/pipelines", web::get().to(list_pipelines))
        .route(
            "/api/v1/pipelines/{pipeline_id}/cancel",
            web::post().to(cancel_pipeline),
        )
        .route("/api/v1/admin/users", web::get().to(list_users))
        .route(
            "/api/v1/admin/users/{user_id}/role",
            web::patch().to(change_user_role),
        )
        .default_service(web::to(not_found));
}

#[cfg(test)]
mod tests {
    use actix_web::{App, http::StatusCode, test};
    use async_trait::async_trait;
    use chrono::{DateTime, Utc};
    use robine_core::{
        identity::{LocalIdentity, OidcClaims, User},
        pipelines::PipelineProjection,
        ports::{IdentityRepository, PipelineRepository, PortError},
    };
    use robine_persistence::PersistenceError;

    use super::*;

    struct StubBackend(bool);

    #[async_trait]
    impl Readiness for StubBackend {
        async fn ready(&self) -> Result<(), PersistenceError> {
            if self.0 {
                Ok(())
            } else {
                Err(PersistenceError::Database(sqlx::Error::PoolClosed))
            }
        }
    }

    #[async_trait]
    impl IdentityRepository for StubBackend {
        async fn bootstrap_administrator(
            &self,
            _user_id: Uuid,
            _credential_id: Uuid,
            _email: &str,
            _password_hash: &str,
            _inserted_at: DateTime<Utc>,
        ) -> Result<User, PortError> {
            Err(PortError::AlreadyBootstrapped)
        }

        async fn get_local_identity(&self, _email: &str) -> Result<LocalIdentity, PortError> {
            Err(PortError::NotFound)
        }

        async fn resolve_session(
            &self,
            _token_digest: &[u8],
            _now: DateTime<Utc>,
        ) -> Result<User, PortError> {
            if self.0 {
                Ok(User {
                    id: Uuid::nil(),
                    email: "user@example.com".into(),
                    role: Role::Viewer,
                    disabled: false,
                    inserted_at: Utc::now(),
                })
            } else {
                Err(PortError::Unavailable)
            }
        }

        async fn create_session(
            &self,
            _id: Uuid,
            _user_id: Uuid,
            _token_digest: &[u8],
            _expires_at: DateTime<Utc>,
            _inserted_at: DateTime<Utc>,
        ) -> Result<(), PortError> {
            Ok(())
        }

        async fn revoke_session(
            &self,
            _token_digest: &[u8],
            _revoked_at: DateTime<Utc>,
        ) -> Result<(), PortError> {
            Ok(())
        }

        async fn list_users(&self) -> Result<Vec<User>, PortError> {
            Ok(Vec::new())
        }

        async fn change_user_role(&self, _user_id: Uuid, _role: Role) -> Result<User, PortError> {
            Err(PortError::NotFound)
        }

        async fn find_or_provision_oidc_user(
            &self,
            _claims: &OidcClaims,
            _user_id: Uuid,
            _inserted_at: DateTime<Utc>,
        ) -> Result<User, PortError> {
            Err(PortError::Unavailable)
        }
    }

    #[async_trait]
    impl PipelineRepository for StubBackend {
        async fn list_recent(
            &self,
            _tenant_id: &str,
            _repository_id: Option<Uuid>,
            _limit: i64,
        ) -> Result<Vec<PipelineProjection>, PortError> {
            Ok(Vec::new())
        }

        async fn cancel(
            &self,
            _tenant_id: &str,
            _pipeline_id: Uuid,
            _event_id: Uuid,
            _now: DateTime<Utc>,
        ) -> Result<PipelineProjection, PortError> {
            Err(PortError::NotFound)
        }
    }

    fn state(ready: bool) -> web::Data<AppState> {
        let backend = Arc::new(StubBackend(ready));
        let control_plane = Arc::new(ControlPlane::new(backend.clone(), backend.clone()));
        web::Data::new(AppState::new(backend, control_plane))
    }

    #[actix_web::test]
    async fn liveness_route_matches_the_existing_contract() {
        let app = test::init_service(App::new().app_data(state(true)).configure(configure)).await;
        let request = test::TestRequest::get().uri("/health/live").to_request();
        let response = test::call_service(&app, request).await;

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[actix_web::test]
    async fn unknown_routes_are_not_found() {
        let app = test::init_service(App::new().app_data(state(true)).configure(configure)).await;
        let request = test::TestRequest::get().uri("/missing").to_request();
        let response = test::call_service(&app, request).await;

        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }

    #[actix_web::test]
    async fn readiness_reflects_database_failure() {
        let app = test::init_service(App::new().app_data(state(false)).configure(configure)).await;
        let request = test::TestRequest::get().uri("/health/ready").to_request();
        let response = test::call_service(&app, request).await;

        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    }

    #[actix_web::test]
    async fn pipeline_api_requires_authentication() {
        let app = test::init_service(App::new().app_data(state(true)).configure(configure)).await;
        let request = test::TestRequest::get()
            .uri("/api/v1/pipelines")
            .to_request();
        let response = test::call_service(&app, request).await;

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[actix_web::test]
    async fn pipeline_api_accepts_an_opaque_session_bearer() {
        let app = test::init_service(App::new().app_data(state(true)).configure(configure)).await;
        let request = test::TestRequest::get()
            .uri("/api/v1/pipelines?limit=10")
            .insert_header(("authorization", "Bearer opaque-session-token"))
            .to_request();
        let response = test::call_service(&app, request).await;

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[actix_web::test]
    async fn sign_in_does_not_reveal_unknown_email() {
        let app = test::init_service(App::new().app_data(state(true)).configure(configure)).await;
        let request = test::TestRequest::post()
            .uri("/api/v1/auth/sign-in")
            .set_json(serde_json::json!({
                "email": "missing@example.com",
                "password": "incorrect"
            }))
            .to_request();
        let response = test::call_service(&app, request).await;

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[actix_web::test]
    async fn sign_out_is_idempotent_without_a_token() {
        let app = test::init_service(App::new().app_data(state(true)).configure(configure)).await;
        let request = test::TestRequest::delete()
            .uri("/api/v1/auth/sign-out")
            .to_request();
        let response = test::call_service(&app, request).await;

        assert_eq!(response.status(), StatusCode::NO_CONTENT);
    }

    #[actix_web::test]
    async fn bootstrap_requires_out_of_band_configuration() {
        let app = test::init_service(App::new().app_data(state(true)).configure(configure)).await;
        let request = test::TestRequest::post()
            .uri("/api/v1/auth/bootstrap")
            .set_json(serde_json::json!({
                "token": "unconfigured",
                "email": "admin@example.com",
                "password": "long-enough-password"
            }))
            .to_request();
        let response = test::call_service(&app, request).await;

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[actix_web::test]
    async fn viewer_cannot_access_identity_administration() {
        let app = test::init_service(App::new().app_data(state(true)).configure(configure)).await;
        let request = test::TestRequest::get()
            .uri("/api/v1/admin/users")
            .insert_header(("authorization", "Bearer viewer-session"))
            .to_request();
        let response = test::call_service(&app, request).await;

        assert_eq!(response.status(), StatusCode::FORBIDDEN);
    }

    #[actix_web::test]
    async fn oidc_is_absent_without_provider_configuration() {
        let app = test::init_service(App::new().app_data(state(true)).configure(configure)).await;
        let request = test::TestRequest::get()
            .uri("/api/v1/auth/oidc")
            .to_request();
        let response = test::call_service(&app, request).await;

        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }
}
