use std::sync::Arc;

use actix_web::{HttpRequest, HttpResponse, Responder, web};
use robine_application::{ApplicationError, ControlPlane};
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
        Err(ApplicationError::Unauthenticated) => return HttpResponse::Unauthorized().finish(),
        Err(ApplicationError::Forbidden) => return HttpResponse::Forbidden().finish(),
        Err(ApplicationError::Unavailable) => return HttpResponse::ServiceUnavailable().finish(),
    };

    match state
        .control_plane
        .list_pipelines(&user, query.repository_id, query.limit.unwrap_or(50))
        .await
    {
        Ok(pipelines) => HttpResponse::Ok().json(pipelines),
        Err(ApplicationError::Unauthenticated) => HttpResponse::Unauthorized().finish(),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(ApplicationError::Unavailable) => HttpResponse::ServiceUnavailable().finish(),
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
        .route("/api/v1/pipelines", web::get().to(list_pipelines))
        .default_service(web::to(not_found));
}

#[cfg(test)]
mod tests {
    use actix_web::{App, http::StatusCode, test};
    use async_trait::async_trait;
    use chrono::{DateTime, Utc};
    use robine_core::{
        identity::{Role, User},
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
                })
            } else {
                Err(PortError::Unavailable)
            }
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
}
