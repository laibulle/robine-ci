use std::sync::Arc;

use actix_web::{HttpRequest, HttpResponse, Responder, web};
use robine_application::{ApplicationError, ControlPlane};
use robine_core::{
    identity::Role,
    pipelines::{CreatePipelineInput, RecordAttemptEvent},
};
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
            | ApplicationError::PipelineNotQueueable
            | ApplicationError::InvalidPipelineInput
            | ApplicationError::IdempotencyConflict
            | ApplicationError::SchedulerCapacity
            | ApplicationError::NoWork
            | ApplicationError::EventSequenceGap { .. }
            | ApplicationError::InvalidAttemptEvent
            | ApplicationError::PipelineNotFound
            | ApplicationError::JobNotRetryable
            | ApplicationError::RetryDependenciesUnavailable(_)
            | ApplicationError::RetryInputsUnavailable(_)
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
            | ApplicationError::PipelineNotQueueable
            | ApplicationError::InvalidPipelineInput
            | ApplicationError::IdempotencyConflict
            | ApplicationError::SchedulerCapacity
            | ApplicationError::NoWork
            | ApplicationError::EventSequenceGap { .. }
            | ApplicationError::InvalidAttemptEvent
            | ApplicationError::PipelineNotFound
            | ApplicationError::JobNotRetryable
            | ApplicationError::RetryDependenciesUnavailable(_)
            | ApplicationError::RetryInputsUnavailable(_)
            | ApplicationError::Unavailable
            | ApplicationError::WeakPassword,
        ) => HttpResponse::ServiceUnavailable().finish(),
    }
}

async fn create_pipeline(
    request: HttpRequest,
    input: web::Json<CreatePipelineInput>,
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
        .create_pipeline(&user, input.into_inner())
        .await
    {
        Ok(pipeline) => HttpResponse::Created().json(pipeline),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(ApplicationError::InvalidPipelineInput) => HttpResponse::UnprocessableEntity().finish(),
        Err(ApplicationError::IdempotencyConflict) => HttpResponse::Conflict().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
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

async fn queue_pipeline(
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
        .queue_pipeline(&user, pipeline_id.into_inner())
        .await
    {
        Ok(pipeline) => HttpResponse::Ok().json(pipeline),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(ApplicationError::PipelineNotFound) => HttpResponse::NotFound().finish(),
        Err(ApplicationError::PipelineNotQueueable) => HttpResponse::Conflict().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

#[derive(Serialize)]
struct RetryConflictResponse {
    error: &'static str,
    unavailable: Vec<String>,
}

async fn retry_job(
    request: HttpRequest,
    job_id: web::Path<Uuid>,
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
        .retry_job(&user, job_id.into_inner())
        .await
    {
        Ok(retry) => HttpResponse::Ok().json(retry),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(ApplicationError::PipelineNotFound) => HttpResponse::NotFound().finish(),
        Err(ApplicationError::JobNotRetryable) => {
            HttpResponse::Conflict().json(RetryConflictResponse {
                error: "job_not_retryable",
                unavailable: Vec::new(),
            })
        }
        Err(ApplicationError::RetryDependenciesUnavailable(unavailable)) => {
            HttpResponse::Conflict().json(RetryConflictResponse {
                error: "retry_dependencies_unavailable",
                unavailable,
            })
        }
        Err(ApplicationError::RetryInputsUnavailable(unavailable)) => HttpResponse::Conflict()
            .json(RetryConflictResponse {
                error: "retry_inputs_unavailable",
                unavailable,
            }),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

#[derive(Deserialize)]
struct SchedulerClaimRequest {
    global_limit: Option<i64>,
    repository_limit: Option<i64>,
    lease_seconds: Option<i64>,
    runner_id: Option<Uuid>,
}

async fn claim_next_job(
    request: HttpRequest,
    input: web::Json<SchedulerClaimRequest>,
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
        .claim_next_job(
            &user,
            input.global_limit.unwrap_or(4),
            input.repository_limit.unwrap_or(2),
            input.lease_seconds.unwrap_or(60),
            input.runner_id,
        )
        .await
    {
        Ok(attempt) => HttpResponse::Ok().json(attempt),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(ApplicationError::SchedulerCapacity) => HttpResponse::TooManyRequests().finish(),
        Err(ApplicationError::NoWork) => HttpResponse::NoContent().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

async fn record_attempt_event(
    request: HttpRequest,
    event: web::Json<RecordAttemptEvent>,
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
        .record_attempt_event(&user, event.into_inner())
        .await
    {
        Ok(attempt) => HttpResponse::Ok().json(attempt),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(ApplicationError::Unauthenticated) => HttpResponse::NotFound().finish(),
        Err(ApplicationError::EventSequenceGap { .. }) => HttpResponse::Conflict().finish(),
        Err(ApplicationError::InvalidAttemptEvent) => HttpResponse::UnprocessableEntity().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

#[derive(Deserialize)]
struct AttemptHeartbeatRequest {
    idempotency_token: Uuid,
    lease_seconds: Option<i64>,
}

async fn heartbeat_attempt(
    request: HttpRequest,
    input: web::Json<AttemptHeartbeatRequest>,
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
        .heartbeat_attempt(
            &user,
            input.idempotency_token,
            input.lease_seconds.unwrap_or(60),
        )
        .await
    {
        Ok(attempt) => HttpResponse::Ok().json(attempt),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(ApplicationError::Unauthenticated) => HttpResponse::NotFound().finish(),
        Err(ApplicationError::InvalidAttemptEvent) => HttpResponse::Conflict().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

#[derive(Deserialize)]
struct ReconcileLeasesRequest {
    limit: Option<i64>,
}

async fn reconcile_expired_attempts(
    request: HttpRequest,
    input: web::Json<ReconcileLeasesRequest>,
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
        .reconcile_expired_attempts(&user, input.limit.unwrap_or(100))
        .await
    {
        Ok(reconciled) => HttpResponse::Ok().json(serde_json::json!({"reconciled": reconciled})),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

#[derive(Deserialize)]
struct RunnerHeartbeatRequest {
    lease_seconds: Option<i64>,
}

async fn heartbeat_runner_attempts(
    request: HttpRequest,
    input: web::Json<RunnerHeartbeatRequest>,
    state: web::Data<AppState>,
) -> impl Responder {
    let runner_id = request
        .headers()
        .get("x-robine-runner-id")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| Uuid::parse_str(value).ok());
    let credential = request
        .headers()
        .get("x-robine-runner-credential")
        .and_then(|value| value.to_str().ok());
    let (Some(runner_id), Some(credential)) = (runner_id, credential) else {
        return HttpResponse::Unauthorized().finish();
    };
    match state
        .control_plane
        .heartbeat_runner_attempts(
            "standalone",
            runner_id,
            credential,
            input.lease_seconds.unwrap_or(60),
        )
        .await
    {
        Ok(heartbeat) => HttpResponse::Ok().json(heartbeat),
        Err(ApplicationError::Unauthenticated) => HttpResponse::Unauthorized().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

#[derive(Deserialize)]
struct RunnerReconciliationRequest {
    #[serde(default)]
    active_attempt_ids: Vec<Uuid>,
}

async fn reconcile_runner_attempts(
    request: HttpRequest,
    input: web::Json<RunnerReconciliationRequest>,
    state: web::Data<AppState>,
) -> impl Responder {
    let runner_id = request
        .headers()
        .get("x-robine-runner-id")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| Uuid::parse_str(value).ok());
    let credential = request
        .headers()
        .get("x-robine-runner-credential")
        .and_then(|value| value.to_str().ok());
    let (Some(runner_id), Some(credential)) = (runner_id, credential) else {
        return HttpResponse::Unauthorized().finish();
    };
    match state
        .control_plane
        .reconcile_runner_attempts(
            "standalone",
            runner_id,
            credential,
            input.into_inner().active_attempt_ids,
        )
        .await
    {
        Ok(reconciliation) => HttpResponse::Ok().json(reconciliation),
        Err(ApplicationError::Unauthenticated) => HttpResponse::Unauthorized().finish(),
        Err(ApplicationError::InvalidAttemptEvent) => HttpResponse::UnprocessableEntity().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

async fn record_remote_attempt_event(
    request: HttpRequest,
    event: web::Json<robine_core::pipelines::RecordRemoteAttemptEvent>,
    state: web::Data<AppState>,
) -> impl Responder {
    let runner_id = request
        .headers()
        .get("x-robine-runner-id")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| Uuid::parse_str(value).ok());
    let credential = request
        .headers()
        .get("x-robine-runner-credential")
        .and_then(|value| value.to_str().ok());
    let (Some(runner_id), Some(credential)) = (runner_id, credential) else {
        return HttpResponse::Unauthorized().finish();
    };
    match state
        .control_plane
        .record_remote_attempt_event("standalone", runner_id, credential, event.into_inner())
        .await
    {
        Ok(attempt) => HttpResponse::Ok().json(attempt),
        Err(ApplicationError::Unauthenticated) => HttpResponse::Unauthorized().finish(),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(ApplicationError::IdempotencyConflict | ApplicationError::EventSequenceGap { .. }) => {
            HttpResponse::Conflict().finish()
        }
        Err(ApplicationError::InvalidAttemptEvent) => HttpResponse::UnprocessableEntity().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

async fn remote_job_offer(
    request: HttpRequest,
    attempt_id: web::Path<Uuid>,
    state: web::Data<AppState>,
) -> impl Responder {
    let runner_id = request
        .headers()
        .get("x-robine-runner-id")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| Uuid::parse_str(value).ok());
    let credential = request
        .headers()
        .get("x-robine-runner-credential")
        .and_then(|value| value.to_str().ok());
    let (Some(runner_id), Some(credential)) = (runner_id, credential) else {
        return HttpResponse::Unauthorized().finish();
    };
    match state
        .control_plane
        .remote_job_offer("standalone", runner_id, credential, attempt_id.into_inner())
        .await
    {
        Ok(offer) => HttpResponse::Ok().json(offer),
        Err(ApplicationError::Unauthenticated) => HttpResponse::Unauthorized().finish(),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(ApplicationError::PipelineNotFound) => HttpResponse::NotFound().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

#[derive(Deserialize)]
struct OutboxProcessRequest {
    limit: Option<usize>,
}

async fn process_outbox(
    request: HttpRequest,
    input: web::Json<OutboxProcessRequest>,
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
    if user.role != Role::Administrator {
        return HttpResponse::Forbidden().finish();
    }
    match state
        .control_plane
        .process_outbox_batch("standalone", input.limit.unwrap_or(25))
        .await
    {
        Ok(batch) => HttpResponse::Ok().json(batch),
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
            | ApplicationError::PipelineNotQueueable
            | ApplicationError::InvalidPipelineInput
            | ApplicationError::IdempotencyConflict
            | ApplicationError::SchedulerCapacity
            | ApplicationError::NoWork
            | ApplicationError::EventSequenceGap { .. }
            | ApplicationError::InvalidAttemptEvent
            | ApplicationError::PipelineNotFound
            | ApplicationError::JobNotRetryable
            | ApplicationError::RetryDependenciesUnavailable(_)
            | ApplicationError::RetryInputsUnavailable(_)
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
            | ApplicationError::PipelineNotQueueable
            | ApplicationError::InvalidPipelineInput
            | ApplicationError::IdempotencyConflict
            | ApplicationError::SchedulerCapacity
            | ApplicationError::NoWork
            | ApplicationError::EventSequenceGap { .. }
            | ApplicationError::InvalidAttemptEvent
            | ApplicationError::PipelineNotFound
            | ApplicationError::JobNotRetryable
            | ApplicationError::RetryDependenciesUnavailable(_)
            | ApplicationError::RetryInputsUnavailable(_)
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
            | ApplicationError::PipelineNotQueueable
            | ApplicationError::InvalidPipelineInput
            | ApplicationError::IdempotencyConflict
            | ApplicationError::SchedulerCapacity
            | ApplicationError::NoWork
            | ApplicationError::EventSequenceGap { .. }
            | ApplicationError::InvalidAttemptEvent
            | ApplicationError::PipelineNotFound
            | ApplicationError::JobNotRetryable
            | ApplicationError::RetryDependenciesUnavailable(_)
            | ApplicationError::RetryInputsUnavailable(_)
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
        .route("/api/v1/pipelines", web::post().to(create_pipeline))
        .route(
            "/api/v1/pipelines/{pipeline_id}/cancel",
            web::post().to(cancel_pipeline),
        )
        .route(
            "/api/v1/pipelines/{pipeline_id}/queue",
            web::post().to(queue_pipeline),
        )
        .route("/api/v1/jobs/{job_id}/retry", web::post().to(retry_job))
        .route(
            "/api/v1/internal/scheduler/claim",
            web::post().to(claim_next_job),
        )
        .route(
            "/api/v1/internal/attempts/events",
            web::post().to(record_attempt_event),
        )
        .route(
            "/api/v1/internal/attempts/heartbeat",
            web::post().to(heartbeat_attempt),
        )
        .route(
            "/api/v1/internal/attempts/reconcile-expired",
            web::post().to(reconcile_expired_attempts),
        )
        .route(
            "/api/v1/runners/heartbeat",
            web::post().to(heartbeat_runner_attempts),
        )
        .route(
            "/api/v1/runners/reconcile",
            web::post().to(reconcile_runner_attempts),
        )
        .route(
            "/api/v1/runners/attempts/events",
            web::post().to(record_remote_attempt_event),
        )
        .route(
            "/api/v1/runners/attempts/{attempt_id}/offer",
            web::get().to(remote_job_offer),
        )
        .route(
            "/api/v1/internal/outbox/process",
            web::post().to(process_outbox),
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
    use hmac::{Hmac, Mac};
    use robine_core::{
        identity::{LocalIdentity, OidcClaims, User},
        pipelines::PipelineProjection,
        ports::{IdentityRepository, PipelineRepository, PortError},
    };
    use robine_persistence::PersistenceError;
    use sha2::Sha256;

    use super::*;

    struct StubBackend {
        ready: bool,
        role: Role,
    }

    #[async_trait]
    impl Readiness for StubBackend {
        async fn ready(&self) -> Result<(), PersistenceError> {
            if self.ready {
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
            if self.ready {
                Ok(User {
                    id: Uuid::nil(),
                    email: "user@example.com".into(),
                    role: self.role,
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
        async fn list_tenants(&self) -> Result<Vec<String>, PortError> {
            Ok(vec!["standalone".into()])
        }

        async fn create(
            &self,
            _tenant_id: &str,
            pipeline: &robine_core::pipelines::NewPipeline,
        ) -> Result<PipelineProjection, PortError> {
            Ok(PipelineProjection {
                id: pipeline.id,
                repository_id: pipeline.repository_id,
                workflow_name: pipeline.workflow_name.clone(),
                commit_sha: pipeline.commit_sha.clone(),
                status: "created".into(),
                inserted_at: pipeline.inserted_at,
            })
        }

        async fn list_recent(
            &self,
            _tenant_id: &str,
            _repository_id: Option<Uuid>,
            _limit: i64,
        ) -> Result<Vec<PipelineProjection>, PortError> {
            Ok(Vec::new())
        }

        async fn queue(
            &self,
            _tenant_id: &str,
            pipeline_id: Uuid,
        ) -> Result<PipelineProjection, PortError> {
            Ok(PipelineProjection {
                id: pipeline_id,
                repository_id: Uuid::nil(),
                workflow_name: "CI".into(),
                commit_sha: "0".repeat(40),
                status: "queued".into(),
                inserted_at: Utc::now(),
            })
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

        async fn retry_job(
            &self,
            _tenant_id: &str,
            job_id: Uuid,
            _event_id: Uuid,
            _now: DateTime<Utc>,
        ) -> Result<robine_core::pipelines::RetryProjection, PortError> {
            Ok(robine_core::pipelines::RetryProjection {
                pipeline_id: Uuid::nil(),
                job_id,
                status: "queued".into(),
                rerun_jobs: Vec::new(),
            })
        }

        async fn claim_next_job(
            &self,
            _tenant_id: &str,
            claim: &robine_core::pipelines::SchedulerClaim,
        ) -> Result<robine_core::pipelines::AttemptProjection, PortError> {
            Ok(robine_core::pipelines::AttemptProjection {
                id: claim.attempt_id,
                job_id: Uuid::nil(),
                number: 1,
                idempotency_token: claim.idempotency_token,
                status: "queued".into(),
                lease_expires_at: claim.now + chrono::Duration::seconds(claim.lease_seconds),
                last_sequence: 0,
                result_reason: None,
            })
        }

        async fn claim_next_dispatch_job(
            &self,
            _tenant_id: &str,
            _claim_token: Uuid,
            _now: DateTime<Utc>,
            _stale_before: DateTime<Utc>,
        ) -> Result<Option<robine_core::pipelines::DurableJobClaim>, PortError> {
            Ok(None)
        }

        async fn complete_durable_job(
            &self,
            _tenant_id: &str,
            _job_id: Uuid,
            _claim_token: Uuid,
            _now: DateTime<Utc>,
        ) -> Result<(), PortError> {
            Ok(())
        }

        async fn retry_durable_job(
            &self,
            _tenant_id: &str,
            _job_id: Uuid,
            _claim_token: Uuid,
            _available_at: DateTime<Utc>,
            _error: &str,
            _discard: bool,
            _now: DateTime<Utc>,
        ) -> Result<(), PortError> {
            Ok(())
        }

        async fn enqueue_local_execution(
            &self,
            _tenant_id: &str,
            _attempt_id: Uuid,
            _now: DateTime<Utc>,
        ) -> Result<(), PortError> {
            Ok(())
        }

        async fn reconcile_local_execution_jobs(
            &self,
            _tenant_id: &str,
            _limit: i64,
            _now: DateTime<Utc>,
        ) -> Result<u64, PortError> {
            Ok(0)
        }

        async fn consume_dispatch_job(
            &self,
            _tenant_id: &str,
            _durable_job_id: Uuid,
            _claim_token: Uuid,
            _claim: &robine_core::pipelines::SchedulerClaim,
        ) -> Result<Option<robine_core::pipelines::AttemptProjection>, PortError> {
            Ok(None)
        }

        async fn record_attempt_event(
            &self,
            _tenant_id: &str,
            _event_id: Uuid,
            event: &RecordAttemptEvent,
            now: DateTime<Utc>,
        ) -> Result<robine_core::pipelines::AttemptProjection, PortError> {
            Ok(robine_core::pipelines::AttemptProjection {
                id: Uuid::nil(),
                job_id: Uuid::nil(),
                number: 1,
                idempotency_token: event.idempotency_token,
                status: event.status.clone(),
                lease_expires_at: now + chrono::Duration::seconds(60),
                last_sequence: event.sequence,
                result_reason: event.reason.clone(),
            })
        }

        async fn heartbeat_attempt(
            &self,
            _tenant_id: &str,
            idempotency_token: Uuid,
            lease_seconds: i64,
            now: DateTime<Utc>,
        ) -> Result<robine_core::pipelines::AttemptProjection, PortError> {
            Ok(robine_core::pipelines::AttemptProjection {
                id: Uuid::nil(),
                job_id: Uuid::nil(),
                number: 1,
                idempotency_token,
                status: "running".into(),
                lease_expires_at: now + chrono::Duration::seconds(lease_seconds),
                last_sequence: 1,
                result_reason: None,
            })
        }

        async fn reconcile_expired_attempts(
            &self,
            _tenant_id: &str,
            _limit: i64,
            _now: DateTime<Utc>,
        ) -> Result<u64, PortError> {
            Ok(1)
        }

        async fn runner_authentication_material(
            &self,
            _tenant_id: &str,
            runner_id: Uuid,
            _now: DateTime<Utc>,
        ) -> Result<robine_core::pipelines::RunnerAuthenticationMaterial, PortError> {
            let mut key_mac =
                Hmac::<Sha256>::new_from_slice(b"runner-test-secret").expect("valid test key");
            key_mac.update(b"robine:runner-credential:v1");
            let key = key_mac.finalize().into_bytes();
            let mut credential_mac =
                Hmac::<Sha256>::new_from_slice(&key).expect("valid derived key");
            credential_mac.update(format!("rrc_{}", "a".repeat(43)).as_bytes());
            Ok(robine_core::pipelines::RunnerAuthenticationMaterial {
                id: runner_id,
                name: "runner".into(),
                admin_state: "enabled".into(),
                credential_digests: vec![credential_mac.finalize().into_bytes().to_vec()],
            })
        }

        async fn heartbeat_runner_attempts(
            &self,
            _tenant_id: &str,
            _runner_id: Uuid,
            _lease_seconds: i64,
            _now: DateTime<Utc>,
        ) -> Result<robine_core::pipelines::RunnerLeaseHeartbeat, PortError> {
            Ok(robine_core::pipelines::RunnerLeaseHeartbeat {
                renewed_attempts: 1,
                cancellation_requested_attempt_ids: Vec::new(),
            })
        }

        async fn reconcile_runner_attempts(
            &self,
            _tenant_id: &str,
            _runner_id: Uuid,
            _now: DateTime<Utc>,
        ) -> Result<Vec<robine_core::pipelines::RunnerResume>, PortError> {
            Ok(vec![robine_core::pipelines::RunnerResume {
                attempt_id: Uuid::nil(),
                acknowledged_sequence: 2,
            }])
        }

        async fn record_remote_attempt_event(
            &self,
            _tenant_id: &str,
            _runner_id: Uuid,
            _receipt_id: Uuid,
            _outbox_event_id: Uuid,
            event: &robine_core::pipelines::RecordRemoteAttemptEvent,
            now: DateTime<Utc>,
        ) -> Result<robine_core::pipelines::AttemptProjection, PortError> {
            Ok(robine_core::pipelines::AttemptProjection {
                id: Uuid::nil(),
                job_id: Uuid::nil(),
                number: 1,
                idempotency_token: event.idempotency_token,
                status: event.status.clone(),
                lease_expires_at: now + chrono::Duration::seconds(60),
                last_sequence: event.sequence,
                result_reason: event.reason.clone(),
            })
        }

        async fn remote_job_offer(
            &self,
            _tenant_id: &str,
            _runner_id: Uuid,
            attempt_id: Uuid,
        ) -> Result<serde_json::Value, PortError> {
            Ok(serde_json::json!({
                "attempt_id": attempt_id,
                "job_key": "test",
                "idempotency_token": Uuid::new_v4()
            }))
        }

        async fn process_next_outbox_event(
            &self,
            _tenant_id: &str,
            _now: DateTime<Utc>,
        ) -> Result<Option<robine_core::pipelines::OutboxDelivery>, PortError> {
            Ok(None)
        }
    }

    fn state(ready: bool) -> web::Data<AppState> {
        state_with_role(ready, Role::Viewer)
    }

    fn state_with_role(ready: bool, role: Role) -> web::Data<AppState> {
        let backend = Arc::new(StubBackend { ready, role });
        let control_plane = Arc::new(
            ControlPlane::new(backend.clone(), backend.clone())
                .with_runner_secret_key_base("runner-test-secret"),
        );
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
    async fn pipeline_creation_validates_and_authorizes_input() {
        let payload = serde_json::json!({
            "repository_id": Uuid::new_v4(),
            "workflow_name": "CI",
            "commit_sha": "e".repeat(40),
            "jobs": {"test": {"execution": {"image": "alpine"}}}
        });
        let viewer_app =
            test::init_service(App::new().app_data(state(true)).configure(configure)).await;
        let viewer = test::TestRequest::post()
            .uri("/api/v1/pipelines")
            .insert_header(("authorization", "Bearer viewer-session"))
            .set_json(&payload)
            .to_request();
        assert_eq!(
            test::call_service(&viewer_app, viewer).await.status(),
            StatusCode::FORBIDDEN
        );

        let maintainer_app = test::init_service(
            App::new()
                .app_data(state_with_role(true, Role::Maintainer))
                .configure(configure),
        )
        .await;
        let invalid = test::TestRequest::post()
            .uri("/api/v1/pipelines")
            .insert_header(("authorization", "Bearer maintainer-session"))
            .set_json(serde_json::json!({
                "repository_id": Uuid::new_v4(),
                "workflow_name": "CI",
                "commit_sha": "invalid"
            }))
            .to_request();
        assert_eq!(
            test::call_service(&maintainer_app, invalid).await.status(),
            StatusCode::UNPROCESSABLE_ENTITY
        );
        let valid = test::TestRequest::post()
            .uri("/api/v1/pipelines")
            .insert_header(("authorization", "Bearer maintainer-session"))
            .set_json(&payload)
            .to_request();
        let response = test::call_service(&maintainer_app, valid).await;
        assert_eq!(response.status(), StatusCode::CREATED);
        let body: serde_json::Value = test::read_body_json(response).await;
        assert_eq!(body["status"], "created");
    }

    #[actix_web::test]
    async fn pipeline_cancellation_requires_a_maintainer() {
        let app = test::init_service(App::new().app_data(state(true)).configure(configure)).await;
        let pipeline_id = Uuid::new_v4();
        let unauthenticated = test::TestRequest::post()
            .uri(&format!("/api/v1/pipelines/{pipeline_id}/cancel"))
            .to_request();
        let unauthenticated_response = test::call_service(&app, unauthenticated).await;
        let viewer = test::TestRequest::post()
            .uri(&format!("/api/v1/pipelines/{pipeline_id}/cancel"))
            .insert_header(("authorization", "Bearer viewer-session"))
            .to_request();
        let viewer_response = test::call_service(&app, viewer).await;

        assert_eq!(unauthenticated_response.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(viewer_response.status(), StatusCode::FORBIDDEN);
    }

    #[actix_web::test]
    async fn pipeline_queue_requires_a_maintainer_and_returns_projection() {
        let pipeline_id = Uuid::new_v4();
        let viewer_app =
            test::init_service(App::new().app_data(state(true)).configure(configure)).await;
        let viewer = test::TestRequest::post()
            .uri(&format!("/api/v1/pipelines/{pipeline_id}/queue"))
            .insert_header(("authorization", "Bearer viewer-session"))
            .to_request();
        let viewer_response = test::call_service(&viewer_app, viewer).await;
        assert_eq!(viewer_response.status(), StatusCode::FORBIDDEN);

        let maintainer_app = test::init_service(
            App::new()
                .app_data(state_with_role(true, Role::Maintainer))
                .configure(configure),
        )
        .await;
        let maintainer = test::TestRequest::post()
            .uri(&format!("/api/v1/pipelines/{pipeline_id}/queue"))
            .insert_header(("authorization", "Bearer maintainer-session"))
            .to_request();
        let response = test::call_service(&maintainer_app, maintainer).await;
        assert_eq!(response.status(), StatusCode::OK);
        let body: serde_json::Value = test::read_body_json(response).await;
        assert_eq!(body["id"], pipeline_id.to_string());
        assert_eq!(body["status"], "queued");
    }

    #[actix_web::test]
    async fn job_retry_requires_a_maintainer() {
        let app = test::init_service(App::new().app_data(state(true)).configure(configure)).await;
        let job_id = Uuid::new_v4();
        let unauthenticated = test::TestRequest::post()
            .uri(&format!("/api/v1/jobs/{job_id}/retry"))
            .to_request();
        let unauthenticated_response = test::call_service(&app, unauthenticated).await;
        let viewer = test::TestRequest::post()
            .uri(&format!("/api/v1/jobs/{job_id}/retry"))
            .insert_header(("authorization", "Bearer viewer-session"))
            .to_request();
        let viewer_response = test::call_service(&app, viewer).await;

        assert_eq!(unauthenticated_response.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(viewer_response.status(), StatusCode::FORBIDDEN);
    }

    #[actix_web::test]
    async fn job_retry_returns_the_requeued_projection() {
        let app = test::init_service(
            App::new()
                .app_data(state_with_role(true, Role::Maintainer))
                .configure(configure),
        )
        .await;
        let job_id = Uuid::new_v4();
        let request = test::TestRequest::post()
            .uri(&format!("/api/v1/jobs/{job_id}/retry"))
            .insert_header(("authorization", "Bearer maintainer-session"))
            .to_request();
        let response = test::call_service(&app, request).await;

        assert_eq!(response.status(), StatusCode::OK);
        let body: serde_json::Value = test::read_body_json(response).await;
        assert_eq!(body["job_id"], job_id.to_string());
        assert_eq!(body["status"], "queued");
    }

    #[actix_web::test]
    async fn scheduler_claim_is_administrator_only_and_returns_a_lease() {
        let maintainer_app = test::init_service(
            App::new()
                .app_data(state_with_role(true, Role::Maintainer))
                .configure(configure),
        )
        .await;
        let maintainer = test::TestRequest::post()
            .uri("/api/v1/internal/scheduler/claim")
            .insert_header(("authorization", "Bearer maintainer-session"))
            .set_json(serde_json::json!({}))
            .to_request();
        assert_eq!(
            test::call_service(&maintainer_app, maintainer)
                .await
                .status(),
            StatusCode::FORBIDDEN
        );

        let administrator_app = test::init_service(
            App::new()
                .app_data(state_with_role(true, Role::Administrator))
                .configure(configure),
        )
        .await;
        let administrator = test::TestRequest::post()
            .uri("/api/v1/internal/scheduler/claim")
            .insert_header(("authorization", "Bearer administrator-session"))
            .set_json(serde_json::json!({
                "global_limit": 2,
                "repository_limit": 1,
                "lease_seconds": 30
            }))
            .to_request();
        let response = test::call_service(&administrator_app, administrator).await;
        assert_eq!(response.status(), StatusCode::OK);
        let body: serde_json::Value = test::read_body_json(response).await;
        assert_eq!(body["number"], 1);
        assert_eq!(body["status"], "queued");
        assert_eq!(body["last_sequence"], 0);
        assert!(body["idempotency_token"].is_string());
    }

    #[actix_web::test]
    async fn attempt_events_are_administrator_owned_and_return_sequence_state() {
        let event = serde_json::json!({
            "idempotency_token": Uuid::new_v4(),
            "sequence": 1,
            "status": "preparing"
        });
        let maintainer_app = test::init_service(
            App::new()
                .app_data(state_with_role(true, Role::Maintainer))
                .configure(configure),
        )
        .await;
        let maintainer = test::TestRequest::post()
            .uri("/api/v1/internal/attempts/events")
            .insert_header(("authorization", "Bearer maintainer-session"))
            .set_json(&event)
            .to_request();
        assert_eq!(
            test::call_service(&maintainer_app, maintainer)
                .await
                .status(),
            StatusCode::FORBIDDEN
        );

        let administrator_app = test::init_service(
            App::new()
                .app_data(state_with_role(true, Role::Administrator))
                .configure(configure),
        )
        .await;
        let administrator = test::TestRequest::post()
            .uri("/api/v1/internal/attempts/events")
            .insert_header(("authorization", "Bearer administrator-session"))
            .set_json(&event)
            .to_request();
        let response = test::call_service(&administrator_app, administrator).await;
        assert_eq!(response.status(), StatusCode::OK);
        let body: serde_json::Value = test::read_body_json(response).await;
        assert_eq!(body["last_sequence"], 1);
        assert_eq!(body["status"], "preparing");
    }

    #[actix_web::test]
    async fn lease_maintenance_is_administrator_owned() {
        let app = test::init_service(
            App::new()
                .app_data(state_with_role(true, Role::Administrator))
                .configure(configure),
        )
        .await;
        let heartbeat = test::TestRequest::post()
            .uri("/api/v1/internal/attempts/heartbeat")
            .insert_header(("authorization", "Bearer administrator-session"))
            .set_json(serde_json::json!({
                "idempotency_token": Uuid::new_v4(),
                "lease_seconds": 90
            }))
            .to_request();
        let heartbeat_response = test::call_service(&app, heartbeat).await;
        assert_eq!(heartbeat_response.status(), StatusCode::OK);
        let heartbeat_body: serde_json::Value = test::read_body_json(heartbeat_response).await;
        assert_eq!(heartbeat_body["status"], "running");

        let reconcile = test::TestRequest::post()
            .uri("/api/v1/internal/attempts/reconcile-expired")
            .insert_header(("authorization", "Bearer administrator-session"))
            .set_json(serde_json::json!({"limit": 10}))
            .to_request();
        let response = test::call_service(&app, reconcile).await;
        assert_eq!(response.status(), StatusCode::OK);
        let body: serde_json::Value = test::read_body_json(response).await;
        assert_eq!(body["reconciled"], 1);

        let outbox = test::TestRequest::post()
            .uri("/api/v1/internal/outbox/process")
            .insert_header(("authorization", "Bearer administrator-session"))
            .set_json(serde_json::json!({"limit": 10}))
            .to_request();
        let outbox_response = test::call_service(&app, outbox).await;
        assert_eq!(outbox_response.status(), StatusCode::OK);
        let outbox_body: serde_json::Value = test::read_body_json(outbox_response).await;
        assert_eq!(outbox_body["processed"], 0);
    }

    #[actix_web::test]
    async fn runner_heartbeat_requires_machine_credentials_and_returns_owned_leases() {
        let app = test::init_service(App::new().app_data(state(true)).configure(configure)).await;
        let missing = test::TestRequest::post()
            .uri("/api/v1/runners/heartbeat")
            .set_json(serde_json::json!({}))
            .to_request();
        assert_eq!(
            test::call_service(&app, missing).await.status(),
            StatusCode::UNAUTHORIZED
        );

        let authenticated = test::TestRequest::post()
            .uri("/api/v1/runners/heartbeat")
            .insert_header(("x-robine-runner-id", Uuid::new_v4().to_string()))
            .insert_header((
                "x-robine-runner-credential",
                format!("rrc_{}", "a".repeat(43)),
            ))
            .set_json(serde_json::json!({"lease_seconds": 90}))
            .to_request();
        let response = test::call_service(&app, authenticated).await;
        assert_eq!(response.status(), StatusCode::OK);
        let body: serde_json::Value = test::read_body_json(response).await;
        assert_eq!(body["renewed_attempts"], 1);
        assert_eq!(
            body["cancellation_requested_attempt_ids"],
            serde_json::json!([])
        );

        let lost = Uuid::new_v4();
        let reconcile = test::TestRequest::post()
            .uri("/api/v1/runners/reconcile")
            .insert_header(("x-robine-runner-id", Uuid::new_v4().to_string()))
            .insert_header((
                "x-robine-runner-credential",
                format!("rrc_{}", "a".repeat(43)),
            ))
            .set_json(serde_json::json!({
                "active_attempt_ids": [Uuid::nil(), lost]
            }))
            .to_request();
        let reconciliation = test::call_service(&app, reconcile).await;
        assert_eq!(reconciliation.status(), StatusCode::OK);
        let reconciliation_body: serde_json::Value = test::read_body_json(reconciliation).await;
        assert_eq!(
            reconciliation_body["resume"][0]["attempt_id"],
            Uuid::nil().to_string()
        );
        assert_eq!(reconciliation_body["resume"][0]["acknowledged_sequence"], 2);
        assert_eq!(reconciliation_body["lease_lost"], serde_json::json!([lost]));

        let remote_event = test::TestRequest::post()
            .uri("/api/v1/runners/attempts/events")
            .insert_header(("x-robine-runner-id", Uuid::new_v4().to_string()))
            .insert_header((
                "x-robine-runner-credential",
                format!("rrc_{}", "a".repeat(43)),
            ))
            .set_json(serde_json::json!({
                "idempotency_token": Uuid::new_v4(),
                "message_id": Uuid::new_v4(),
                "sequence": 1,
                "status": "preparing"
            }))
            .to_request();
        let event_response = test::call_service(&app, remote_event).await;
        assert_eq!(event_response.status(), StatusCode::OK);
        let event_body: serde_json::Value = test::read_body_json(event_response).await;
        assert_eq!(event_body["last_sequence"], 1);
        assert_eq!(event_body["status"], "preparing");

        let offer_attempt_id = Uuid::new_v4();
        let offer_request = test::TestRequest::get()
            .uri(&format!(
                "/api/v1/runners/attempts/{offer_attempt_id}/offer"
            ))
            .insert_header(("x-robine-runner-id", Uuid::new_v4().to_string()))
            .insert_header((
                "x-robine-runner-credential",
                format!("rrc_{}", "a".repeat(43)),
            ))
            .to_request();
        let offer_response = test::call_service(&app, offer_request).await;
        assert_eq!(offer_response.status(), StatusCode::OK);
        let offer: serde_json::Value = test::read_body_json(offer_response).await;
        assert_eq!(offer["attempt_id"], offer_attempt_id.to_string());
        assert_eq!(offer["job_key"], "test");
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
