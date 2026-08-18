use std::{
    collections::{HashMap, VecDeque},
    fmt::Write as _,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use actix_web::{
    HttpRequest, HttpResponse, Responder,
    cookie::{Cookie, SameSite, time::Duration as CookieDuration},
    http::header,
    web,
};
use futures_util::StreamExt;
use hmac::{Hmac, Mac};
use robine_application::{ApplicationError, ControlPlane};
use robine_core::{
    identity::Role,
    pipelines::{CreatePipelineInput, RecordAttemptEvent, SourceControlDelivery},
};
use robine_persistence::Readiness;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use uuid::Uuid;

#[derive(Clone)]
pub struct AppState {
    readiness: Arc<dyn Readiness>,
    control_plane: Arc<ControlPlane>,
    failure_limiter: Arc<FailureLimiter>,
    webhooks: Arc<WebhookConfiguration>,
}

#[derive(Clone, Default)]
pub struct WebhookConfiguration {
    github: Option<String>,
    gitlab: Option<String>,
    forgejo: Option<String>,
}

impl WebhookConfiguration {
    #[must_use]
    pub fn new(github: Option<String>, gitlab: Option<String>, forgejo: Option<String>) -> Self {
        Self {
            github,
            gitlab,
            forgejo,
        }
    }
}

impl AppState {
    #[must_use]
    pub fn new(readiness: Arc<dyn Readiness>, control_plane: Arc<ControlPlane>) -> Self {
        Self {
            readiness,
            control_plane,
            failure_limiter: Arc::new(FailureLimiter::default()),
            webhooks: Arc::new(WebhookConfiguration::default()),
        }
    }

    #[must_use]
    pub fn with_webhooks(mut self, configuration: WebhookConfiguration) -> Self {
        self.webhooks = Arc::new(configuration);
        self
    }
}

#[derive(Default)]
struct FailureLimiter {
    attempts: Mutex<HashMap<String, VecDeque<Instant>>>,
}

impl FailureLimiter {
    fn attempt(&self, key: &str) -> bool {
        let now = Instant::now();
        let mut attempts = self
            .attempts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        attempts.retain(|_, entries| {
            while entries
                .front()
                .is_some_and(|at| now.duration_since(*at) >= Duration::from_mins(1))
            {
                entries.pop_front();
            }
            !entries.is_empty()
        });
        let entries = attempts.entry(key.to_owned()).or_default();
        if entries.len() >= 10 {
            return false;
        }
        entries.push_back(now);
        true
    }

    fn clear(&self, key: &str) {
        self.attempts
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(key);
    }
}

fn request_source(request: &HttpRequest) -> String {
    request
        .peer_addr()
        .map_or_else(|| "unknown".into(), |address| address.ip().to_string())
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

const RUNNER_TOPIC: &str = "runner:v1";

#[derive(Deserialize)]
struct RunnerHello {
    supported_protocol_versions: Vec<i32>,
    software_version: String,
    capabilities: serde_json::Value,
    #[serde(default)]
    active_attempt_ids: Vec<Uuid>,
}

#[derive(Deserialize)]
struct RunnerSocketDecision {
    attempt_id: Uuid,
    message_id: String,
}

#[derive(Deserialize)]
struct RunnerSocketLog {
    attempt_id: Uuid,
    sequence: i64,
    step_position: i32,
    step_name: String,
    stream: String,
    content: String,
}

async fn runner_state_message(
    control_plane: &ControlPlane,
    runner_id: Uuid,
    credential: &str,
    event: &str,
    payload: serde_json::Value,
) -> serde_json::Value {
    if event == "log_event" {
        let Ok(log) = serde_json::from_value::<RunnerSocketLog>(payload) else {
            return protocol_error("invalid_log_event");
        };
        let result = control_plane
            .record_remote_log(
                "standalone",
                runner_id,
                credential,
                robine_core::pipelines::ExecutionLogChunk {
                    id: Uuid::nil(),
                    attempt_id: log.attempt_id,
                    sequence: log.sequence,
                    step_position: log.step_position,
                    step_name: log.step_name,
                    stream: log.stream,
                    content: log.content.into_bytes(),
                    inserted_at: chrono::DateTime::<chrono::Utc>::UNIX_EPOCH,
                },
            )
            .await;
        return match result {
            Ok(sequence) => protocol_ok(&serde_json::json!({"sequence":sequence})),
            Err(error) => runner_application_error(&error, "invalid_log_event"),
        };
    }

    let remote_event = if event == "attempt_event" {
        serde_json::from_value::<robine_core::pipelines::RecordRemoteAttemptEvent>(payload).ok()
    } else if matches!(event, "job_accept" | "job_reject") {
        let Ok(decision) = serde_json::from_value::<RunnerSocketDecision>(payload) else {
            return protocol_error(if event == "job_accept" {
                "invalid_job_accept"
            } else {
                "invalid_job_reject"
            });
        };
        if decision.message_id.is_empty() || decision.message_id.len() > 128 {
            return protocol_error("invalid_offer_decision");
        }
        let Ok(offer) = control_plane
            .remote_job_offer("standalone", runner_id, credential, decision.attempt_id)
            .await
        else {
            return protocol_error("invalid_offer_decision");
        };
        offer
            .get("idempotency_token")
            .and_then(serde_json::Value::as_str)
            .and_then(|token| Uuid::parse_str(token).ok())
            .map(
                |idempotency_token| robine_core::pipelines::RecordRemoteAttemptEvent {
                    idempotency_token,
                    message_id: decision.message_id,
                    sequence: 1,
                    status: if event == "job_accept" {
                        "preparing".into()
                    } else {
                        "failed".into()
                    },
                    reason: (event == "job_reject").then(|| "system_failure".into()),
                },
            )
    } else {
        return protocol_error("unsupported_message");
    };
    let Some(remote_event) = remote_event else {
        return protocol_error("invalid_attempt_event");
    };
    match control_plane
        .record_remote_attempt_event("standalone", runner_id, credential, remote_event.clone())
        .await
    {
        Ok(attempt) => protocol_ok(&serde_json::json!({
            "message_id":remote_event.message_id,
            "attempt_id":attempt.id,
            "acknowledged_sequence":attempt.last_sequence
        })),
        Err(error) => runner_application_error(&error, "invalid_attempt_event"),
    }
}

fn protocol_ok(response: &serde_json::Value) -> serde_json::Value {
    serde_json::json!({"status":"ok","response":response})
}

fn protocol_error(code: &str) -> serde_json::Value {
    serde_json::json!({"status":"error","response":{"code":code}})
}

fn runner_application_error(error: &ApplicationError, fallback: &str) -> serde_json::Value {
    match error {
        ApplicationError::EventSequenceGap { expected, actual } => serde_json::json!({
            "status":"error","response":{"code":"event_gap","expected_sequence":expected,"received_sequence":actual}
        }),
        ApplicationError::IdempotencyConflict => protocol_error("message_id_conflict"),
        ApplicationError::Unauthenticated | ApplicationError::Forbidden => {
            protocol_error("unauthorized")
        }
        _ => protocol_error(fallback),
    }
}

#[allow(clippy::too_many_lines)]
async fn runner_socket(
    request: HttpRequest,
    body: web::Payload,
    state: web::Data<AppState>,
) -> Result<HttpResponse, actix_web::Error> {
    let runner_id = request
        .headers()
        .get("x-robine-runner-id")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| Uuid::parse_str(value).ok());
    let credential = request
        .headers()
        .get("x-robine-runner-credential")
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let rate_key = format!(
        "runner-auth:{}:{}",
        request_source(&request),
        runner_id.map_or_else(|| "invalid".into(), |id| id.to_string())
    );
    if !state.failure_limiter.attempt(&rate_key) {
        return Ok(HttpResponse::TooManyRequests()
            .insert_header(("retry-after", "60"))
            .finish());
    }
    let (Some(runner_id), Some(credential)) = (runner_id, credential) else {
        let _ = state
            .control_plane
            .audit_runner_authentication_failure("standalone", runner_id, chrono::Utc::now())
            .await;
        return Ok(HttpResponse::Unauthorized().finish());
    };
    let (response, mut session, mut messages) = actix_ws::handle(&request, body)?;
    let control_plane = state.control_plane.clone();
    let failure_limiter = state.failure_limiter.clone();
    actix_web::rt::spawn(async move {
        let mut joined = false;
        while let Some(Ok(message)) = messages.next().await {
            match message {
                actix_ws::Message::Text(text) if text.len() <= 262_144 => {
                    let Ok(frame) = serde_json::from_str::<Vec<serde_json::Value>>(&text) else {
                        let _ = session
                            .close(Some(actix_ws::CloseReason {
                                code: actix_ws::CloseCode::Protocol,
                                description: Some("malformed_message".into()),
                            }))
                            .await;
                        break;
                    };
                    if frame.len() != 5 {
                        continue;
                    }
                    let join_ref = frame[0].clone();
                    let message_ref = frame[1].clone();
                    let topic = frame[2].as_str().unwrap_or_default();
                    let event = frame[3].as_str().unwrap_or_default();
                    if !joined && topic == RUNNER_TOPIC && event == "phx_join" {
                        let hello = serde_json::from_value::<RunnerHello>(frame[4].clone());
                        let response_body = match hello {
                            Ok(hello) if !hello.supported_protocol_versions.contains(&1) => {
                                serde_json::json!({
                                    "status":"error","response":{"code":"incompatible_protocol","supported_protocol_versions":[1]}
                                })
                            }
                            Ok(hello) => match control_plane
                                .negotiate_runner_session(
                                    "standalone",
                                    runner_id,
                                    &credential,
                                    &hello.supported_protocol_versions,
                                    &hello.software_version,
                                    &hello.capabilities,
                                )
                                .await
                            {
                                Ok(protocol_version) => {
                                    match control_plane
                                        .reconcile_runner_attempts(
                                            "standalone",
                                            runner_id,
                                            &credential,
                                            hello.active_attempt_ids,
                                        )
                                        .await
                                    {
                                        Ok(reconciliation) => {
                                            joined = true;
                                            failure_limiter.clear(&rate_key);
                                            serde_json::json!({"status":"ok","response":{
                                                "protocol_version":protocol_version,
                                                "heartbeat_interval_seconds":20,
                                                "stale_after_seconds":60,
                                                "resume":reconciliation.resume,
                                                "lease_lost":reconciliation.lease_lost
                                            }})
                                        }
                                        Err(_) => {
                                            serde_json::json!({"status":"error","response":{"code":"unavailable"}})
                                        }
                                    }
                                }
                                Err(ApplicationError::InvalidAttemptEvent) => {
                                    serde_json::json!({"status":"error","response":{"code":"invalid_hello"}})
                                }
                                Err(ApplicationError::Unauthenticated) => {
                                    serde_json::json!({"status":"error","response":{"code":"unauthorized"}})
                                }
                                Err(_) => {
                                    serde_json::json!({"status":"error","response":{"code":"unavailable"}})
                                }
                            },
                            Err(_) => {
                                serde_json::json!({"status":"error","response":{"code":"invalid_hello"}})
                            }
                        };
                        let reply = serde_json::json!([
                            join_ref,
                            message_ref,
                            RUNNER_TOPIC,
                            "phx_reply",
                            response_body
                        ]);
                        if session.text(reply.to_string()).await.is_err() {
                            break;
                        }
                    } else if joined && topic == RUNNER_TOPIC && event == "heartbeat" {
                        let heartbeat = control_plane
                            .heartbeat_runner_attempts("standalone", runner_id, &credential, 60)
                            .await;
                        let body = match &heartbeat {
                            Ok(heartbeat) => {
                                serde_json::json!({"status":"ok","response":heartbeat})
                            }
                            Err(_) => {
                                serde_json::json!({"status":"error","response":{"code":"unauthorized"}})
                            }
                        };
                        let reply = serde_json::json!([
                            join_ref,
                            message_ref,
                            RUNNER_TOPIC,
                            "phx_reply",
                            body
                        ]);
                        if session.text(reply.to_string()).await.is_err() {
                            break;
                        }
                        if let Ok(heartbeat) = heartbeat {
                            for attempt_id in heartbeat.pending_offer_attempt_ids {
                                if let Ok(offer) = control_plane
                                    .remote_job_offer(
                                        "standalone",
                                        runner_id,
                                        &credential,
                                        attempt_id,
                                    )
                                    .await
                                {
                                    let push = serde_json::json!([
                                        null,
                                        null,
                                        RUNNER_TOPIC,
                                        "job_offer",
                                        offer
                                    ]);
                                    if session.text(push.to_string()).await.is_err() {
                                        break;
                                    }
                                }
                            }
                            for attempt_id in heartbeat.cancellation_requested_attempt_ids {
                                let push = serde_json::json!([null,null,RUNNER_TOPIC,"cancel",{"attempt_id":attempt_id}]);
                                if session.text(push.to_string()).await.is_err() {
                                    break;
                                }
                            }
                        }
                    } else if joined && topic == RUNNER_TOPIC {
                        let body = runner_state_message(
                            &control_plane,
                            runner_id,
                            &credential,
                            event,
                            frame[4].clone(),
                        )
                        .await;
                        let reply = serde_json::json!([
                            join_ref,
                            message_ref,
                            RUNNER_TOPIC,
                            "phx_reply",
                            body
                        ]);
                        if session.text(reply.to_string()).await.is_err() {
                            break;
                        }
                    }
                }
                actix_ws::Message::Ping(bytes) => {
                    if session.pong(&bytes).await.is_err() {
                        break;
                    }
                }
                actix_ws::Message::Close(reason) => {
                    let _ = session.close(reason).await;
                    break;
                }
                actix_ws::Message::Text(_) | actix_ws::Message::Binary(_) => {
                    let _ = session
                        .close(Some(actix_ws::CloseReason {
                            code: actix_ws::CloseCode::Size,
                            description: Some("message_too_large".into()),
                        }))
                        .await;
                    break;
                }
                _ => {}
            }
        }
    });
    Ok(response)
}

#[derive(Deserialize)]
struct PipelineQuery {
    repository_id: Option<Uuid>,
    limit: Option<i64>,
}

#[derive(Deserialize)]
struct RunnerEnrollmentRequest {
    token: String,
    name: String,
}

async fn enroll_runner(
    request: HttpRequest,
    input: web::Json<RunnerEnrollmentRequest>,
    state: web::Data<AppState>,
) -> HttpResponse {
    let rate_key = format!("runner-enrollment:{}", request_source(&request));
    if !state.failure_limiter.attempt(&rate_key) {
        return HttpResponse::TooManyRequests()
            .insert_header(("retry-after", "60"))
            .json(serde_json::json!({"error":"too many enrollment attempts"}));
    }
    match state
        .control_plane
        .enroll_runner("standalone", &input.token, &input.name)
        .await
    {
        Ok(identity) => {
            state.failure_limiter.clear(&rate_key);
            HttpResponse::Created()
                .insert_header(("cache-control", "no-store"))
                .json(identity)
        }
        Err(ApplicationError::InvalidCredentials) => HttpResponse::Unauthorized()
            .json(serde_json::json!({"error":"invalid enrollment token"})),
        Err(ApplicationError::InvalidPipelineInput) => HttpResponse::BadRequest()
            .json(serde_json::json!({"error":"invalid enrollment request"})),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

async fn create_runner_enrollment(
    request: HttpRequest,
    state: web::Data<AppState>,
) -> HttpResponse {
    let Ok(actor) = authenticated_user(&request, &state).await else {
        return HttpResponse::Unauthorized().finish();
    };
    match state
        .control_plane
        .create_runner_enrollment("standalone", &actor)
        .await
    {
        Ok(enrollment) => HttpResponse::Created()
            .insert_header(("cache-control", "no-store"))
            .json(enrollment),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

async fn rotate_runner_credential(
    request: HttpRequest,
    runner_id: web::Path<Uuid>,
    state: web::Data<AppState>,
) -> HttpResponse {
    let Ok(actor) = authenticated_user(&request, &state).await else {
        return HttpResponse::Unauthorized().finish();
    };
    match state
        .control_plane
        .rotate_runner_credential("standalone", &actor, runner_id.into_inner())
        .await
    {
        Ok(identity) => HttpResponse::Ok()
            .insert_header(("cache-control", "no-store"))
            .json(identity),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(ApplicationError::PipelineNotFound) => HttpResponse::NotFound().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

async fn revoke_runner(
    request: HttpRequest,
    runner_id: web::Path<Uuid>,
    state: web::Data<AppState>,
) -> HttpResponse {
    let Ok(actor) = authenticated_user(&request, &state).await else {
        return HttpResponse::Unauthorized().finish();
    };
    match state
        .control_plane
        .revoke_runner("standalone", &actor, runner_id.into_inner())
        .await
    {
        Ok(()) => HttpResponse::NoContent().finish(),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(ApplicationError::PipelineNotFound) => HttpResponse::NotFound().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

async fn list_runner_fleet(request: HttpRequest, state: web::Data<AppState>) -> HttpResponse {
    let Ok(actor) = authenticated_user(&request, &state).await else {
        return HttpResponse::Unauthorized().finish();
    };
    match state
        .control_plane
        .list_runner_fleet("standalone", &actor)
        .await
    {
        Ok(runners) => HttpResponse::Ok().json(serde_json::json!({"runners":runners})),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

#[derive(Deserialize)]
struct ConfigureRunnerRequest {
    name: String,
    #[serde(default)]
    labels: Vec<String>,
    admin_state: String,
}

async fn configure_runner(
    request: HttpRequest,
    runner_id: web::Path<Uuid>,
    input: web::Json<ConfigureRunnerRequest>,
    state: web::Data<AppState>,
) -> HttpResponse {
    let Ok(actor) = authenticated_user(&request, &state).await else {
        return HttpResponse::Unauthorized().finish();
    };
    let input = input.into_inner();
    match state
        .control_plane
        .configure_runner(
            "standalone",
            &actor,
            runner_id.into_inner(),
            &input.name,
            input.labels,
            &input.admin_state,
        )
        .await
    {
        Ok(()) => HttpResponse::NoContent().finish(),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(ApplicationError::InvalidPipelineInput) => HttpResponse::UnprocessableEntity().finish(),
        Err(ApplicationError::PipelineNotFound) => HttpResponse::NotFound().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

#[derive(Deserialize)]
struct BrowserRunnerForm {
    csrf_token: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    labels: String,
    #[serde(default)]
    admin_state: String,
}

async fn runner_fleet_page(request: HttpRequest, state: web::Data<AppState>) -> HttpResponse {
    let Ok((actor, token)) = browser_administrator(&request, &state).await else {
        return HttpResponse::Unauthorized().finish();
    };
    match state
        .control_plane
        .list_runner_fleet("standalone", &actor)
        .await
    {
        Ok(runners) => render_runner_fleet(&runners, &csrf_token(&token), None),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

async fn browser_create_runner_enrollment(
    request: HttpRequest,
    input: web::Form<BrowserRunnerForm>,
    state: web::Data<AppState>,
) -> HttpResponse {
    let Ok((actor, token)) = browser_administrator(&request, &state).await else {
        return HttpResponse::Unauthorized().finish();
    };
    if !valid_csrf(&input.csrf_token, &token) {
        return HttpResponse::Forbidden().finish();
    }
    let Ok(enrollment) = state
        .control_plane
        .create_runner_enrollment("standalone", &actor)
        .await
    else {
        return HttpResponse::ServiceUnavailable().finish();
    };
    let Ok(runners) = state
        .control_plane
        .list_runner_fleet("standalone", &actor)
        .await
    else {
        return HttpResponse::ServiceUnavailable().finish();
    };
    let notice = format!(
        "Copy now — expires {}: ROBINE_RUNNER_ENROLLMENT_TOKEN='{}' robine-runner enroll --server SERVER_URL --name RUNNER_NAME --config /etc/robine-runner/config.json",
        enrollment.expires_at.to_rfc3339(),
        enrollment.token
    );
    render_runner_fleet(&runners, &csrf_token(&token), Some(&notice))
}

async fn browser_configure_runner(
    request: HttpRequest,
    runner_id: web::Path<Uuid>,
    input: web::Form<BrowserRunnerForm>,
    state: web::Data<AppState>,
) -> HttpResponse {
    let Ok((actor, token)) = browser_administrator(&request, &state).await else {
        return HttpResponse::Unauthorized().finish();
    };
    if !valid_csrf(&input.csrf_token, &token) {
        return HttpResponse::Forbidden().finish();
    }
    let labels = input
        .labels
        .split(',')
        .map(str::trim)
        .filter(|label| !label.is_empty())
        .map(str::to_owned)
        .collect();
    match state
        .control_plane
        .configure_runner(
            "standalone",
            &actor,
            runner_id.into_inner(),
            &input.name,
            labels,
            &input.admin_state,
        )
        .await
    {
        Ok(()) => HttpResponse::SeeOther()
            .insert_header((header::LOCATION, "/admin/runners"))
            .finish(),
        Err(ApplicationError::InvalidPipelineInput) => HttpResponse::UnprocessableEntity().finish(),
        Err(ApplicationError::PipelineNotFound) => HttpResponse::NotFound().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

async fn browser_rotate_runner(
    request: HttpRequest,
    runner_id: web::Path<Uuid>,
    input: web::Form<BrowserRunnerForm>,
    state: web::Data<AppState>,
) -> HttpResponse {
    let Ok((actor, token)) = browser_administrator(&request, &state).await else {
        return HttpResponse::Unauthorized().finish();
    };
    if !valid_csrf(&input.csrf_token, &token) {
        return HttpResponse::Forbidden().finish();
    }
    let rotated = match state
        .control_plane
        .rotate_runner_credential("standalone", &actor, runner_id.into_inner())
        .await
    {
        Ok(rotated) => rotated,
        Err(ApplicationError::PipelineNotFound) => return HttpResponse::NotFound().finish(),
        Err(_) => return HttpResponse::ServiceUnavailable().finish(),
    };
    let Ok(runners) = state
        .control_plane
        .list_runner_fleet("standalone", &actor)
        .await
    else {
        return HttpResponse::ServiceUnavailable().finish();
    };
    render_runner_fleet(
        &runners,
        &csrf_token(&token),
        Some(&format!(
            "Copy the replacement credential now: {}",
            rotated.credential
        )),
    )
}

async fn browser_revoke_runner(
    request: HttpRequest,
    runner_id: web::Path<Uuid>,
    input: web::Form<BrowserRunnerForm>,
    state: web::Data<AppState>,
) -> HttpResponse {
    let Ok((actor, token)) = browser_administrator(&request, &state).await else {
        return HttpResponse::Unauthorized().finish();
    };
    if !valid_csrf(&input.csrf_token, &token) {
        return HttpResponse::Forbidden().finish();
    }
    match state
        .control_plane
        .revoke_runner("standalone", &actor, runner_id.into_inner())
        .await
    {
        Ok(()) => HttpResponse::SeeOther()
            .insert_header((header::LOCATION, "/admin/runners"))
            .finish(),
        Err(ApplicationError::PipelineNotFound) => HttpResponse::NotFound().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

async fn browser_administrator(
    request: &HttpRequest,
    state: &web::Data<AppState>,
) -> Result<(robine_core::identity::User, String), ApplicationError> {
    let token = session_token(request).ok_or(ApplicationError::Unauthenticated)?;
    let actor = state.control_plane.authenticate(&token).await?;
    if actor.role != Role::Administrator || actor.disabled {
        return Err(ApplicationError::Forbidden);
    }
    Ok((actor, token))
}

fn csrf_token(session_token: &str) -> String {
    let digest = Sha256::digest(format!("robine:csrf:v1:{session_token}"));
    digest
        .iter()
        .fold(String::with_capacity(64), |mut output, byte| {
            let _ = write!(output, "{byte:02x}");
            output
        })
}

fn valid_csrf(candidate: &str, session_token: &str) -> bool {
    let expected = csrf_token(session_token);
    candidate.len() == expected.len() && bool::from(candidate.as_bytes().ct_eq(expected.as_bytes()))
}

fn escape_html(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn render_runner_fleet(
    runners: &[robine_core::pipelines::RunnerFleetEntry],
    csrf: &str,
    notice: Option<&str>,
) -> HttpResponse {
    let mut cards = String::new();
    for runner in runners {
        let labels = runner
            .labels
            .iter()
            .fold(String::new(), |mut output, label| {
                let _ = write!(output, "<span class=\"chip\">{}</span>", escape_html(label));
                output
            });
        let last_seen = runner
            .last_seen_at
            .map_or_else(|| "never".into(), |seen| seen.to_rfc3339());
        let disabled = runner.admin_state == "revoked";
        let next_state = if runner.admin_state == "draining" {
            "enabled"
        } else {
            "draining"
        };
        let _ = write!(
            cards,
            "<article class=\"runner-card\" id=\"runner-{}\"><header><div><h2>{}</h2><p><span class=\"status {}\">{}</span> <span class=\"status\">{}</span></p></div><strong>{}/{} active</strong></header><p class=\"meta\">{} · last heartbeat {} · {} slots available</p><div class=\"chips\">{}</div>",
            runner.id,
            escape_html(&runner.name),
            escape_html(&runner.connectivity),
            escape_html(&runner.admin_state),
            escape_html(&runner.connectivity),
            runner.active_attempts,
            runner.concurrency,
            escape_html(
                runner
                    .software_version
                    .as_deref()
                    .unwrap_or("version unknown")
            ),
            escape_html(&last_seen),
            runner.available_slots,
            labels
        );
        if !disabled {
            let _ = write!(
                cards,
                "<form method=\"post\" action=\"/admin/runners/{}/configure\" class=\"config-grid\"><input type=\"hidden\" name=\"csrf_token\" value=\"{}\"><label>Name<input name=\"name\" required maxlength=\"80\" value=\"{}\"></label><label>Labels<input name=\"labels\" value=\"{}\"></label><input type=\"hidden\" name=\"admin_state\" value=\"{}\"><button type=\"submit\">Save and {}</button></form><div class=\"danger-zone\"><form method=\"post\" action=\"/admin/runners/{}/rotate\"><input type=\"hidden\" name=\"csrf_token\" value=\"{}\"><button>Rotate credential</button></form><form method=\"post\" action=\"/admin/runners/{}/revoke\"><input type=\"hidden\" name=\"csrf_token\" value=\"{}\"><button class=\"danger\">Revoke immediately</button></form></div>",
                runner.id,
                csrf,
                escape_html(&runner.name),
                escape_html(&runner.labels.join(", ")),
                next_state,
                if next_state == "draining" {
                    "drain"
                } else {
                    "enable"
                },
                runner.id,
                csrf,
                runner.id,
                csrf
            );
        }
        cards.push_str("</article>");
    }
    if cards.is_empty() {
        cards.push_str("<p class=\"empty\">No remote runner is enrolled yet.</p>");
    }
    let notice = notice.map_or_else(String::new, |value| format!("<aside class=\"secret\" role=\"status\"><strong>One-time secret</strong><code>{}</code></aside>", escape_html(value)));
    let html = format!(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Runner fleet · Robine</title><link rel=\"stylesheet\" href=\"/assets/app.css\"></head><body><main><nav><span class=\"brand\">Robine</span><a aria-current=\"page\" href=\"/admin/runners\">Runner fleet</a></nav><section class=\"hero\"><p class=\"eyebrow\">Infrastructure</p><h1>Runner fleet</h1><p>Operate trusted build capacity without exposing permanent storage credentials.</p><form method=\"post\" action=\"/admin/runners/enrollments\"><input type=\"hidden\" name=\"csrf_token\" value=\"{csrf}\"><button class=\"primary\">Generate enrollment command</button></form></section>{notice}<section class=\"fleet\">{cards}</section></main></body></html>"
    );
    HttpResponse::Ok()
        .insert_header((header::CACHE_CONTROL, "no-store"))
        .content_type("text/html; charset=utf-8")
        .body(html)
}

async fn application_css() -> HttpResponse {
    HttpResponse::Ok()
        .content_type("text/css; charset=utf-8")
        .body(include_str!("../assets/app.css"))
}

async fn authenticated_user(
    request: &HttpRequest,
    state: &web::Data<AppState>,
) -> Result<robine_core::identity::User, ApplicationError> {
    let token = session_token(request).ok_or(ApplicationError::Unauthenticated)?;
    state.control_plane.authenticate(&token).await
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
            | ApplicationError::InvalidWorkflow(_)
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
            | ApplicationError::InvalidWorkflow(_)
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
        Err(ApplicationError::InvalidWorkflow(diagnostics)) => HttpResponse::UnprocessableEntity()
            .json(serde_json::json!({"diagnostics": diagnostics})),
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

async fn remote_attempt_source(
    request: HttpRequest,
    attempt_id: web::Path<Uuid>,
    state: web::Data<AppState>,
) -> HttpResponse {
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
        .remote_attempt_source("standalone", runner_id, credential, attempt_id.into_inner())
        .await
    {
        Ok(archive) => HttpResponse::Ok()
            .insert_header(("cache-control", "no-store"))
            .content_type("application/gzip")
            .body(archive),
        Err(ApplicationError::Unauthenticated) => HttpResponse::Unauthorized().finish(),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(ApplicationError::PipelineNotFound) => HttpResponse::NotFound().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

async fn remote_attempt_secrets(
    request: HttpRequest,
    attempt_id: web::Path<Uuid>,
    state: web::Data<AppState>,
) -> HttpResponse {
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
        .remote_attempt_secrets("standalone", runner_id, credential, attempt_id.into_inner())
        .await
    {
        Ok(body) => HttpResponse::Ok()
            .insert_header(("cache-control", "no-store"))
            .content_type("application/json")
            .body(body),
        Err(ApplicationError::Unauthenticated) => HttpResponse::Unauthorized().finish(),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(ApplicationError::PipelineNotFound) => HttpResponse::NotFound().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

#[derive(Deserialize)]
struct RemoteLogRequest {
    sequence: i64,
    step_position: i32,
    step_name: String,
    stream: String,
    content: String,
}

async fn record_remote_log(
    request: HttpRequest,
    attempt_id: web::Path<Uuid>,
    input: web::Json<RemoteLogRequest>,
    state: web::Data<AppState>,
) -> HttpResponse {
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
    let input = input.into_inner();
    match state
        .control_plane
        .record_remote_log(
            "standalone",
            runner_id,
            credential,
            robine_core::pipelines::ExecutionLogChunk {
                id: Uuid::nil(),
                attempt_id: attempt_id.into_inner(),
                sequence: input.sequence,
                step_position: input.step_position,
                step_name: input.step_name,
                stream: input.stream,
                content: input.content.into_bytes(),
                inserted_at: chrono::DateTime::<chrono::Utc>::UNIX_EPOCH,
            },
        )
        .await
    {
        Ok(sequence) => HttpResponse::Ok().json(serde_json::json!({"sequence": sequence})),
        Err(ApplicationError::Unauthenticated) => HttpResponse::Unauthorized().finish(),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(ApplicationError::PipelineNotFound) => HttpResponse::NotFound().finish(),
        Err(ApplicationError::InvalidAttemptEvent) => HttpResponse::UnprocessableEntity().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

#[derive(Deserialize)]
struct RemoteCacheQuery {
    key: String,
}

async fn restore_remote_cache(
    request: HttpRequest,
    attempt_id: web::Path<Uuid>,
    query: web::Query<RemoteCacheQuery>,
    state: web::Data<AppState>,
) -> HttpResponse {
    let Some((runner_id, credential)) = runner_headers(&request) else {
        return HttpResponse::Unauthorized().finish();
    };
    match state
        .control_plane
        .remote_restore_cache(
            "standalone",
            runner_id,
            credential,
            attempt_id.into_inner(),
            &query.key,
        )
        .await
    {
        Ok(Some(download)) => transfer_download(download),
        Ok(None) => HttpResponse::NoContent().finish(),
        Err(error) => remote_transfer_error(&error),
    }
}

async fn save_remote_cache(
    request: HttpRequest,
    attempt_id: web::Path<Uuid>,
    query: web::Query<RemoteCacheQuery>,
    body: web::Bytes,
    state: web::Data<AppState>,
) -> HttpResponse {
    let Some((runner_id, credential)) = runner_headers(&request) else {
        return HttpResponse::Unauthorized().finish();
    };
    match state
        .control_plane
        .remote_save_cache(
            "standalone",
            runner_id,
            credential,
            attempt_id.into_inner(),
            &query.key,
            body.to_vec(),
        )
        .await
    {
        Ok(upload) => HttpResponse::Created().json(upload),
        Err(error) => remote_transfer_error(&error),
    }
}

#[derive(Deserialize)]
struct RemoteArtifactQuery {
    name: String,
    from: Option<String>,
    retention_days: Option<i64>,
}

async fn download_remote_artifact(
    request: HttpRequest,
    attempt_id: web::Path<Uuid>,
    query: web::Query<RemoteArtifactQuery>,
    state: web::Data<AppState>,
) -> HttpResponse {
    let Some((runner_id, credential)) = runner_headers(&request) else {
        return HttpResponse::Unauthorized().finish();
    };
    let Some(from_job) = query.from.as_deref() else {
        return HttpResponse::UnprocessableEntity().finish();
    };
    match state
        .control_plane
        .remote_download_artifact(
            "standalone",
            runner_id,
            credential,
            attempt_id.into_inner(),
            from_job,
            &query.name,
        )
        .await
    {
        Ok(download) => transfer_download(download),
        Err(error) => remote_transfer_error(&error),
    }
}

async fn upload_remote_artifact(
    request: HttpRequest,
    attempt_id: web::Path<Uuid>,
    query: web::Query<RemoteArtifactQuery>,
    body: web::Bytes,
    state: web::Data<AppState>,
) -> HttpResponse {
    let Some((runner_id, credential)) = runner_headers(&request) else {
        return HttpResponse::Unauthorized().finish();
    };
    match state
        .control_plane
        .remote_upload_artifact(
            "standalone",
            runner_id,
            credential,
            attempt_id.into_inner(),
            &query.name,
            query.retention_days.unwrap_or(7),
            body.to_vec(),
        )
        .await
    {
        Ok(upload) => HttpResponse::Created().json(upload),
        Err(error) => remote_transfer_error(&error),
    }
}

fn runner_headers(request: &HttpRequest) -> Option<(Uuid, &str)> {
    let runner_id = request
        .headers()
        .get("x-robine-runner-id")?
        .to_str()
        .ok()
        .and_then(|value| Uuid::parse_str(value).ok())?;
    let credential = request
        .headers()
        .get("x-robine-runner-credential")?
        .to_str()
        .ok()?;
    Some((runner_id, credential))
}

fn transfer_download(download: robine_application::RemoteTransferDownload) -> HttpResponse {
    HttpResponse::Ok()
        .insert_header(("cache-control", "no-store"))
        .insert_header(("x-content-sha256", download.digest))
        .content_type("application/gzip")
        .body(download.content)
}

fn remote_transfer_error(error: &ApplicationError) -> HttpResponse {
    match error {
        ApplicationError::Unauthenticated => HttpResponse::Unauthorized().finish(),
        ApplicationError::Forbidden => HttpResponse::Forbidden().finish(),
        ApplicationError::PipelineNotFound => HttpResponse::NotFound().finish(),
        ApplicationError::InvalidAttemptEvent => HttpResponse::UnprocessableEntity().finish(),
        _ => HttpResponse::ServiceUnavailable().finish(),
    }
}

#[derive(Deserialize)]
struct RunnerOfferDecision {
    message_id: String,
}

async fn accept_remote_job(
    request: HttpRequest,
    attempt_id: web::Path<Uuid>,
    input: web::Json<RunnerOfferDecision>,
    state: web::Data<AppState>,
) -> HttpResponse {
    decide_remote_job(
        &request,
        attempt_id.into_inner(),
        input.into_inner(),
        "preparing",
        None,
        &state,
    )
    .await
}

async fn reject_remote_job(
    request: HttpRequest,
    attempt_id: web::Path<Uuid>,
    input: web::Json<RunnerOfferDecision>,
    state: web::Data<AppState>,
) -> HttpResponse {
    decide_remote_job(
        &request,
        attempt_id.into_inner(),
        input.into_inner(),
        "failed",
        Some("system_failure".into()),
        &state,
    )
    .await
}

async fn decide_remote_job(
    request: &HttpRequest,
    attempt_id: Uuid,
    input: RunnerOfferDecision,
    status: &str,
    reason: Option<String>,
    state: &web::Data<AppState>,
) -> HttpResponse {
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
    if input.message_id.is_empty() || input.message_id.len() > 128 {
        return HttpResponse::UnprocessableEntity().finish();
    }
    let offer = match state
        .control_plane
        .remote_job_offer("standalone", runner_id, credential, attempt_id)
        .await
    {
        Ok(offer) => offer,
        Err(ApplicationError::Unauthenticated) => return HttpResponse::Unauthorized().finish(),
        Err(ApplicationError::Forbidden) => return HttpResponse::Forbidden().finish(),
        Err(ApplicationError::PipelineNotFound) => return HttpResponse::NotFound().finish(),
        Err(_) => return HttpResponse::ServiceUnavailable().finish(),
    };
    let Some(idempotency_token) = offer
        .get("idempotency_token")
        .and_then(serde_json::Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
    else {
        return HttpResponse::ServiceUnavailable().finish();
    };
    match state
        .control_plane
        .record_remote_attempt_event(
            "standalone",
            runner_id,
            credential,
            robine_core::pipelines::RecordRemoteAttemptEvent {
                idempotency_token,
                message_id: input.message_id.clone(),
                sequence: 1,
                status: status.into(),
                reason,
            },
        )
        .await
    {
        Ok(attempt) => HttpResponse::Ok().json(serde_json::json!({
            "message_id": input.message_id,
            "attempt_id": attempt_id,
            "acknowledged_sequence": attempt.last_sequence,
        })),
        Err(ApplicationError::Unauthenticated) => HttpResponse::Unauthorized().finish(),
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(ApplicationError::IdempotencyConflict | ApplicationError::EventSequenceGap { .. }) => {
            HttpResponse::Conflict().finish()
        }
        Err(ApplicationError::InvalidAttemptEvent) => HttpResponse::UnprocessableEntity().finish(),
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

async fn sign_in(
    request: HttpRequest,
    input: web::Json<SignInRequest>,
    state: web::Data<AppState>,
) -> impl Responder {
    match state
        .control_plane
        .authenticate_local(&input.email, &input.password)
        .await
    {
        Ok(session) => {
            let cookie = session_cookie(&request, &session.token);
            HttpResponse::Ok().cookie(cookie).json(session)
        }
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
            | ApplicationError::InvalidWorkflow(_)
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

async fn browser_sign_in_page() -> HttpResponse {
    HttpResponse::Ok()
        .insert_header((header::CACHE_CONTROL, "no-store"))
        .content_type("text/html; charset=utf-8")
        .body("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Sign in · Robine</title><link rel=\"stylesheet\" href=\"/assets/app.css\"></head><body><main><section class=\"hero auth\"><p class=\"eyebrow\">Robine control plane</p><h1>Welcome back</h1><p>Sign in to operate pipelines and trusted runner capacity.</p><form method=\"post\" action=\"/sign-in\" class=\"auth-form\"><label>Email<input type=\"email\" name=\"email\" autocomplete=\"username\" required></label><label>Password<input type=\"password\" name=\"password\" autocomplete=\"current-password\" required></label><button class=\"primary\" type=\"submit\">Sign in</button></form></section></main></body></html>")
}

async fn browser_sign_in(
    request: HttpRequest,
    input: web::Form<SignInRequest>,
    state: web::Data<AppState>,
) -> HttpResponse {
    match state
        .control_plane
        .authenticate_local(&input.email, &input.password)
        .await
    {
        Ok(session) => HttpResponse::SeeOther()
            .cookie(session_cookie(&request, &session.token))
            .insert_header((header::LOCATION, "/admin/runners"))
            .finish(),
        Err(ApplicationError::InvalidCredentials | ApplicationError::Unauthenticated) => {
            HttpResponse::Unauthorized().finish()
        }
        Err(ApplicationError::Forbidden) => HttpResponse::Forbidden().finish(),
        Err(_) => HttpResponse::ServiceUnavailable().finish(),
    }
}

fn session_cookie(request: &HttpRequest, token: &str) -> Cookie<'static> {
    Cookie::build("robine_session", token.to_owned())
        .path("/")
        .http_only(true)
        .secure(request.connection_info().scheme() == "https")
        .same_site(SameSite::Lax)
        .max_age(CookieDuration::hours(8))
        .finish()
}

async fn sign_out(request: HttpRequest, state: web::Data<AppState>) -> impl Responder {
    let Some(token) = session_token(&request) else {
        return HttpResponse::NoContent().finish();
    };

    match state.control_plane.revoke_session(&token).await {
        Ok(()) | Err(ApplicationError::Unauthenticated | ApplicationError::InvalidCredentials) => {
            let mut expired = Cookie::build("robine_session", "").path("/").finish();
            expired.make_removal();
            HttpResponse::NoContent().cookie(expired).finish()
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
            | ApplicationError::InvalidWorkflow(_)
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
            | ApplicationError::InvalidWorkflow(_)
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

fn session_token(request: &HttpRequest) -> Option<String> {
    bearer_token(request).map(str::to_owned).or_else(|| {
        request
            .cookie("robine_session")
            .map(|cookie| cookie.value().to_owned())
    })
}

const MAX_WEBHOOK_BYTES: usize = 1_048_576;

#[derive(Clone, Copy)]
enum WebhookProvider {
    GitHub,
    GitLab,
    Forgejo,
}

impl WebhookProvider {
    const fn name(self) -> &'static str {
        match self {
            Self::GitHub => "github",
            Self::GitLab => "gitlab",
            Self::Forgejo => "forgejo",
        }
    }
}

async fn github_webhook(
    request: HttpRequest,
    body: web::Bytes,
    state: web::Data<AppState>,
) -> HttpResponse {
    receive_webhook(request, body, state, WebhookProvider::GitHub).await
}

async fn gitlab_webhook(
    request: HttpRequest,
    body: web::Bytes,
    state: web::Data<AppState>,
) -> HttpResponse {
    receive_webhook(request, body, state, WebhookProvider::GitLab).await
}

async fn forgejo_webhook(
    request: HttpRequest,
    body: web::Bytes,
    state: web::Data<AppState>,
) -> HttpResponse {
    receive_webhook(request, body, state, WebhookProvider::Forgejo).await
}

async fn receive_webhook(
    request: HttpRequest,
    body: web::Bytes,
    state: web::Data<AppState>,
    provider: WebhookProvider,
) -> HttpResponse {
    let (delivery_header, event_header, authentication_header) = match provider {
        WebhookProvider::GitHub => ("x-github-delivery", "x-github-event", "x-hub-signature-256"),
        WebhookProvider::GitLab => ("x-gitlab-event-uuid", "x-gitlab-event", "x-gitlab-token"),
        WebhookProvider::Forgejo => (
            "x-forgejo-delivery",
            "x-forgejo-event",
            "x-forgejo-signature",
        ),
    };
    let Some(delivery_id) = bounded_header(&request, delivery_header, 255) else {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "headers"}));
    };
    let Some(event) = bounded_header(&request, event_header, 64) else {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "headers"}));
    };
    let Some(authentication) = bounded_header(&request, authentication_header, 16_384) else {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "headers"}));
    };
    if body.len() > MAX_WEBHOOK_BYTES {
        return HttpResponse::PayloadTooLarge().finish();
    }
    let secret = match provider {
        WebhookProvider::GitHub => state.webhooks.github.as_deref(),
        WebhookProvider::GitLab => state.webhooks.gitlab.as_deref(),
        WebhookProvider::Forgejo => state.webhooks.forgejo.as_deref(),
    };
    let Some(secret) = secret else {
        return HttpResponse::ServiceUnavailable()
            .json(serde_json::json!({"error": "temporarily unavailable"}));
    };
    if !valid_webhook_authentication(provider, secret, &body, authentication) {
        return HttpResponse::Unauthorized()
            .json(serde_json::json!({"error": "invalid signature"}));
    }
    let Ok(payload) = serde_json::from_slice::<serde_json::Value>(&body) else {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "json"}));
    };
    if !payload.is_object() {
        return HttpResponse::BadRequest().json(serde_json::json!({"error": "payload"}));
    }
    let provider_name = provider.name();
    let id = if matches!(provider, WebhookProvider::GitHub) {
        delivery_id.to_owned()
    } else {
        let mut digest = Sha256::new();
        digest.update(delivery_id.as_bytes());
        format!("{provider_name}:default:{:x}", digest.finalize())
    };
    let delivery = SourceControlDelivery {
        id,
        provider: provider_name.into(),
        provider_instance: "default".into(),
        provider_delivery_id: delivery_id.into(),
        event: event.into(),
        payload,
        received_at: chrono::Utc::now(),
    };
    match state
        .control_plane
        .accept_source_control_delivery("standalone", &delivery)
        .await
    {
        Ok(true) => HttpResponse::Accepted().json(serde_json::json!({"status": "accepted"})),
        Ok(false) => HttpResponse::Ok().json(serde_json::json!({"status": "duplicate"})),
        Err(_) => HttpResponse::ServiceUnavailable()
            .json(serde_json::json!({"error": "temporarily unavailable"})),
    }
}

fn bounded_header<'a>(request: &'a HttpRequest, name: &str, max: usize) -> Option<&'a str> {
    request
        .headers()
        .get(name)?
        .to_str()
        .ok()
        .filter(|value| !value.is_empty() && value.len() <= max)
}

fn valid_webhook_authentication(
    provider: WebhookProvider,
    secret: &str,
    body: &[u8],
    authentication: &str,
) -> bool {
    if matches!(provider, WebhookProvider::GitLab) {
        return secret.len() == authentication.len()
            && secret.as_bytes().ct_eq(authentication.as_bytes()).into();
    }
    let signature = if matches!(provider, WebhookProvider::GitHub) {
        authentication.strip_prefix("sha256=")
    } else {
        Some(authentication)
    };
    let Some(signature) = signature.filter(|value| value.len() == 64) else {
        return false;
    };
    let Ok(mut mac) = Hmac::<Sha256>::new_from_slice(secret.as_bytes()) else {
        return false;
    };
    mac.update(body);
    let expected = format!("{:x}", mac.finalize().into_bytes());
    expected.as_bytes().ct_eq(signature.as_bytes()).into()
}

#[allow(clippy::too_many_lines)]
pub fn configure(config: &mut web::ServiceConfig) {
    config
        .app_data(web::PayloadConfig::new(MAX_WEBHOOK_BYTES))
        .route("/api/github/webhooks", web::post().to(github_webhook))
        .route("/api/gitlab/webhooks", web::post().to(gitlab_webhook))
        .route("/api/forgejo/webhooks", web::post().to(forgejo_webhook))
        .route("/runner/socket/websocket", web::get().to(runner_socket))
        .route("/health/live", web::get().to(live))
        .route("/assets/app.css", web::get().to(application_css))
        .route("/sign-in", web::get().to(browser_sign_in_page))
        .route("/sign-in", web::post().to(browser_sign_in))
        .route("/admin/runners", web::get().to(runner_fleet_page))
        .route(
            "/admin/runners/enrollments",
            web::post().to(browser_create_runner_enrollment),
        )
        .route(
            "/admin/runners/{runner_id}/configure",
            web::post().to(browser_configure_runner),
        )
        .route(
            "/admin/runners/{runner_id}/rotate",
            web::post().to(browser_rotate_runner),
        )
        .route(
            "/admin/runners/{runner_id}/revoke",
            web::post().to(browser_revoke_runner),
        )
        .route("/health/ready", web::get().to(ready))
        .route("/api/v1/auth/bootstrap", web::post().to(bootstrap))
        .route("/api/v1/auth/sign-in", web::post().to(sign_in))
        .route("/api/v1/auth/sign-out", web::delete().to(sign_out))
        .route("/api/v1/runners/enroll", web::post().to(enroll_runner))
        .route(
            "/api/v1/admin/runners/enrollments",
            web::post().to(create_runner_enrollment),
        )
        .route(
            "/api/v1/admin/runners/{runner_id}/rotate",
            web::post().to(rotate_runner_credential),
        )
        .route(
            "/api/v1/admin/runners/{runner_id}",
            web::delete().to(revoke_runner),
        )
        .route("/api/v1/admin/runners", web::get().to(list_runner_fleet))
        .route(
            "/api/v1/admin/runners/{runner_id}",
            web::patch().to(configure_runner),
        )
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
            "/api/v1/runners/attempts/{attempt_id}/source",
            web::get().to(remote_attempt_source),
        )
        .route(
            "/api/v1/runners/attempts/{attempt_id}/secrets",
            web::get().to(remote_attempt_secrets),
        )
        .route(
            "/api/v1/runners/attempts/{attempt_id}/logs",
            web::post().to(record_remote_log),
        )
        .service(
            web::resource("/api/v1/runners/attempts/{attempt_id}/cache")
                .app_data(web::PayloadConfig::new(100_000_000))
                .route(web::get().to(restore_remote_cache))
                .route(web::put().to(save_remote_cache)),
        )
        .service(
            web::resource("/api/v1/runners/attempts/{attempt_id}/artifacts")
                .app_data(web::PayloadConfig::new(100_000_000))
                .route(web::get().to(download_remote_artifact))
                .route(web::put().to(upload_remote_artifact)),
        )
        .route(
            "/api/v1/runners/attempts/{attempt_id}/accept",
            web::post().to(accept_remote_job),
        )
        .route(
            "/api/v1/runners/attempts/{attempt_id}/reject",
            web::post().to(reject_remote_job),
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
    use robine_source::{
        ArchiveFetcher, Provider, Repository, RepositoryStore, SourceError, SourceFile,
    };
    use sha2::Sha256;
    use std::path::PathBuf;

    use super::*;

    struct StubBackend {
        ready: bool,
        role: Role,
    }

    struct StubSource;

    #[async_trait]
    impl RepositoryStore for StubSource {
        async fn find_trusted(
            &self,
            _tenant_id: &str,
            repository_id: Uuid,
        ) -> Result<Repository, SourceError> {
            Ok(Repository {
                id: repository_id,
                provider: Provider::GitHub,
                provider_instance: "https://github.com".into(),
                installation_id: 1,
                owner: "robine".into(),
                name: "fixture".into(),
                full_name: "robine/fixture".into(),
            })
        }
    }

    #[async_trait]
    impl ArchiveFetcher for StubSource {
        async fn fetch_archive(
            &self,
            _repository: &Repository,
            _commit_sha: &str,
        ) -> Result<Vec<u8>, SourceError> {
            robine_source::create_source_tar_gz(
                &[SourceFile {
                    path: PathBuf::from("README.md"),
                    contents: b"remote source\n".to_vec(),
                }],
                robine_source::ArchiveLimits::default(),
            )
        }
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

        async fn accept_source_control_delivery(
            &self,
            _tenant_id: &str,
            _delivery: &robine_core::pipelines::SourceControlDelivery,
        ) -> Result<bool, PortError> {
            Ok(true)
        }

        async fn record_runner_session(
            &self,
            _tenant_id: &str,
            _runner_id: Uuid,
            _protocol_version: i32,
            _software_version: &str,
            _capabilities: &serde_json::Value,
            _now: DateTime<Utc>,
        ) -> Result<(), PortError> {
            Ok(())
        }

        async fn create_runner_enrollment(
            &self,
            _tenant_id: &str,
            _enrollment: &robine_core::pipelines::NewRunnerEnrollment,
        ) -> Result<(), PortError> {
            Ok(())
        }

        async fn consume_runner_enrollment(
            &self,
            _tenant_id: &str,
            _enrollment: &robine_core::pipelines::ConsumeRunnerEnrollment,
        ) -> Result<(), PortError> {
            Ok(())
        }

        async fn rotate_runner_credential(
            &self,
            _tenant_id: &str,
            _credential: &robine_core::pipelines::RotateRunnerCredential,
        ) -> Result<(), PortError> {
            Ok(())
        }

        async fn revoke_runner(
            &self,
            _tenant_id: &str,
            _revocation: &robine_core::pipelines::RevokeRunner,
        ) -> Result<(), PortError> {
            Ok(())
        }

        async fn list_runner_fleet(
            &self,
            _tenant_id: &str,
            _now: DateTime<Utc>,
        ) -> Result<Vec<robine_core::pipelines::RunnerFleetEntry>, PortError> {
            Ok(vec![robine_core::pipelines::RunnerFleetEntry {
                id: Uuid::nil(),
                name: "edge-builder".into(),
                admin_state: "enabled".into(),
                connectivity: "online".into(),
                labels: vec!["linux".into()],
                capabilities: serde_json::json!({"docker":true,"concurrency":2}),
                protocol_version: Some(1),
                software_version: Some("0.3.0".into()),
                last_seen_at: Some(Utc::now()),
                active_attempts: 1,
                concurrency: 2,
                available_slots: 1,
            }])
        }

        async fn configure_runner(
            &self,
            _tenant_id: &str,
            _configuration: &robine_core::pipelines::ConfigureRunner,
        ) -> Result<(), PortError> {
            Ok(())
        }

        async fn audit_runner_authentication_failure(
            &self,
            _tenant_id: &str,
            _claimed_runner_id: Option<Uuid>,
            _audit_id: Uuid,
            _correlation_id: Uuid,
            _now: DateTime<Utc>,
        ) -> Result<(), PortError> {
            Ok(())
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

        async fn claim_next_execution_job(
            &self,
            _tenant_id: &str,
            _claim_token: Uuid,
            _now: DateTime<Utc>,
            _stale_before: DateTime<Utc>,
        ) -> Result<Option<robine_core::pipelines::DurableJobClaim>, PortError> {
            Ok(None)
        }

        async fn local_execution_work(
            &self,
            _tenant_id: &str,
            _attempt_id: Uuid,
        ) -> Result<robine_core::pipelines::LocalExecutionWork, PortError> {
            Err(PortError::NotFound)
        }

        async fn append_execution_log(
            &self,
            _tenant_id: &str,
            _chunk: &robine_core::pipelines::ExecutionLogChunk,
        ) -> Result<(), PortError> {
            Ok(())
        }

        async fn cancellation_requested(
            &self,
            _tenant_id: &str,
            _idempotency_token: Uuid,
        ) -> Result<bool, PortError> {
            Ok(false)
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
                pending_offer_attempt_ids: vec![Uuid::nil()],
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
                "idempotency_token": Uuid::new_v4(),
                "repository_id": Uuid::nil(),
                "commit_sha": "a".repeat(40),
                "steps": [{"kind": "builtin", "value": "checkout"}]
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
                .with_runner_secret_key_base("runner-test-secret")
                .with_source_runtime(Arc::new(StubSource), Arc::new(StubSource)),
        );
        web::Data::new(AppState::new(backend, control_plane))
    }

    fn webhook_state() -> web::Data<AppState> {
        let backend = Arc::new(StubBackend {
            ready: true,
            role: Role::Viewer,
        });
        let control_plane = Arc::new(ControlPlane::new(backend.clone(), backend.clone()));
        web::Data::new(AppState::new(backend, control_plane).with_webhooks(
            WebhookConfiguration::new(
                Some("github-secret".into()),
                Some("gitlab-secret".into()),
                Some("forgejo-secret".into()),
            ),
        ))
    }

    fn signature(secret: &str, body: &[u8]) -> String {
        let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("valid HMAC key");
        mac.update(body);
        format!("{:x}", mac.finalize().into_bytes())
    }

    #[actix_web::test]
    async fn liveness_route_matches_the_existing_contract() {
        let app = test::init_service(App::new().app_data(state(true)).configure(configure)).await;
        let request = test::TestRequest::get().uri("/health/live").to_request();
        let response = test::call_service(&app, request).await;

        assert_eq!(response.status(), StatusCode::OK);
    }

    #[actix_web::test]
    async fn github_webhook_authenticates_raw_body_before_json_decoding() {
        let app =
            test::init_service(App::new().app_data(webhook_state()).configure(configure)).await;
        let request = test::TestRequest::post()
            .uri("/api/github/webhooks")
            .insert_header(("x-github-delivery", "delivery-1"))
            .insert_header(("x-github-event", "push"))
            .insert_header(("x-hub-signature-256", format!("sha256={}", "0".repeat(64))))
            .set_payload("not-json")
            .to_request();
        let response = test::call_service(&app, request).await;
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[actix_web::test]
    async fn configured_provider_webhooks_accept_valid_authentication() {
        let app =
            test::init_service(App::new().app_data(webhook_state()).configure(configure)).await;
        let body = br#"{"repository":{"id":1}}"#;
        let github_signature = signature("github-secret", body);
        let cases = [
            (
                "/api/github/webhooks",
                "x-github-delivery",
                "x-github-event",
                "x-hub-signature-256",
                format!("sha256={github_signature}"),
            ),
            (
                "/api/gitlab/webhooks",
                "x-gitlab-event-uuid",
                "x-gitlab-event",
                "x-gitlab-token",
                "gitlab-secret".into(),
            ),
            (
                "/api/forgejo/webhooks",
                "x-forgejo-delivery",
                "x-forgejo-event",
                "x-forgejo-signature",
                signature("forgejo-secret", body),
            ),
        ];
        for (uri, delivery_header, event_header, auth_header, authentication) in cases {
            let request = test::TestRequest::post()
                .uri(uri)
                .insert_header((delivery_header, Uuid::new_v4().to_string()))
                .insert_header((event_header, "push"))
                .insert_header((auth_header, authentication))
                .set_payload(body.as_slice())
                .to_request();
            let response = test::call_service(&app, request).await;
            assert_eq!(response.status(), StatusCode::ACCEPTED, "{uri}");
        }
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

        let source_backed = test::TestRequest::post()
            .uri("/api/v1/pipelines")
            .insert_header(("authorization", "Bearer maintainer-session"))
            .set_json(serde_json::json!({
                "repository_id": Uuid::new_v4(),
                "commit_sha": "f".repeat(40),
                "trigger": "push",
                "workflow_revision": {
                    "path": ".robine-ci/workflows/ci.yml",
                    "source": "version: 1\nname: Source CI\non: {push: {}}\njobs:\n  test:\n    image: alpine:3.22\n    steps: [{run: echo ok}]\n"
                }
            }))
            .to_request();
        assert_eq!(
            test::call_service(&maintainer_app, source_backed)
                .await
                .status(),
            StatusCode::CREATED
        );

        let invalid_workflow = test::TestRequest::post()
            .uri("/api/v1/pipelines")
            .insert_header(("authorization", "Bearer maintainer-session"))
            .set_json(serde_json::json!({
                "repository_id": Uuid::new_v4(),
                "commit_sha": "a".repeat(40),
                "trigger": "push",
                "workflow_revision": {
                    "path": ".robine-ci/workflows/broken.yml",
                    "source": "version: 1\nname: Broken\non: ["
                }
            }))
            .to_request();
        let response = test::call_service(&maintainer_app, invalid_workflow).await;
        assert_eq!(response.status(), StatusCode::UNPROCESSABLE_ENTITY);
        let body: serde_json::Value = test::read_body_json(response).await;
        assert_eq!(body["diagnostics"][0]["code"], "workflow.yaml");
        assert_eq!(
            body["diagnostics"][0]["source_path"],
            ".robine-ci/workflows/broken.yml"
        );
        assert!(
            body["diagnostics"][0]["line"]
                .as_u64()
                .is_some_and(|line| line > 0)
        );
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
    async fn runner_fleet_browser_is_cookie_authenticated_and_csrf_protected() {
        let app = test::init_service(
            App::new()
                .app_data(state_with_role(true, Role::Administrator))
                .configure(configure),
        )
        .await;
        let sign_in_page = test::TestRequest::get().uri("/sign-in").to_request();
        let sign_in_response = test::call_service(&app, sign_in_page).await;
        assert_eq!(sign_in_response.status(), StatusCode::OK);
        let sign_in_body = String::from_utf8(test::read_body(sign_in_response).await.to_vec())
            .expect("sign-in HTML");
        assert!(sign_in_body.contains("action=\"/sign-in\""));
        assert!(sign_in_body.contains("autocomplete=\"current-password\""));
        let unauthenticated = test::TestRequest::get().uri("/admin/runners").to_request();
        assert_eq!(
            test::call_service(&app, unauthenticated).await.status(),
            StatusCode::UNAUTHORIZED
        );

        let page = test::TestRequest::get()
            .uri("/admin/runners")
            .cookie(Cookie::new("robine_session", "admin-session"))
            .to_request();
        let page_response = test::call_service(&app, page).await;
        assert_eq!(page_response.status(), StatusCode::OK);
        assert_eq!(
            page_response
                .headers()
                .get("cache-control")
                .and_then(|value| value.to_str().ok()),
            Some("no-store")
        );
        let page_body =
            String::from_utf8(test::read_body(page_response).await.to_vec()).expect("HTML");
        assert!(page_body.contains("<h1>Runner fleet</h1>"));
        assert!(page_body.contains("id=\"runner-00000000-0000-0000-0000-000000000000\""));
        assert!(page_body.contains("edge-builder"));
        assert!(page_body.contains("Rotate credential"));

        let forged = test::TestRequest::post()
            .uri("/admin/runners/enrollments")
            .cookie(Cookie::new("robine_session", "admin-session"))
            .set_form(serde_json::json!({"csrf_token":"forged"}))
            .to_request();
        assert_eq!(
            test::call_service(&app, forged).await.status(),
            StatusCode::FORBIDDEN
        );

        let valid = test::TestRequest::post()
            .uri("/admin/runners/enrollments")
            .cookie(Cookie::new("robine_session", "admin-session"))
            .set_form(serde_json::json!({"csrf_token":csrf_token("admin-session")}))
            .to_request();
        let valid_response = test::call_service(&app, valid).await;
        assert_eq!(valid_response.status(), StatusCode::OK);
        let valid_body =
            String::from_utf8(test::read_body(valid_response).await.to_vec()).expect("HTML");
        assert!(valid_body.contains("One-time secret"));
        assert!(valid_body.contains("ROBINE_RUNNER_ENROLLMENT_TOKEN"));

        let css = test::TestRequest::get().uri("/assets/app.css").to_request();
        let css_response = test::call_service(&app, css).await;
        assert_eq!(css_response.status(), StatusCode::OK);
        assert_eq!(
            css_response
                .headers()
                .get("content-type")
                .and_then(|value| value.to_str().ok()),
            Some("text/css; charset=utf-8")
        );
    }

    #[actix_web::test]
    async fn runner_enrollment_failures_are_rate_limited_per_source() {
        let app = test::init_service(App::new().app_data(state(true)).configure(configure)).await;
        let peer = "192.0.2.44:41000".parse().expect("peer address");
        for attempt in 0..11 {
            let request = test::TestRequest::post()
                .uri("/api/v1/runners/enroll")
                .peer_addr(peer)
                .set_json(serde_json::json!({"token":"invalid","name":"runner"}))
                .to_request();
            let response = test::call_service(&app, request).await;
            if attempt < 10 {
                assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
            } else {
                assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
                assert_eq!(
                    response
                        .headers()
                        .get("retry-after")
                        .and_then(|value| value.to_str().ok()),
                    Some("60")
                );
            }
        }
    }

    #[actix_web::test]
    async fn runner_socket_authentication_is_rate_limited_per_source_and_identity() {
        let app = test::init_service(App::new().app_data(state(true)).configure(configure)).await;
        let peer = "192.0.2.45:42000".parse().expect("peer address");
        let runner_id = Uuid::new_v4();
        for attempt in 0..11 {
            let request = test::TestRequest::get()
                .uri("/runner/socket/websocket?vsn=2.0.0")
                .peer_addr(peer)
                .insert_header(("x-robine-runner-id", runner_id.to_string()))
                .to_request();
            let response = test::call_service(&app, request).await;
            if attempt < 10 {
                assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
            } else {
                assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
                assert_eq!(
                    response
                        .headers()
                        .get("retry-after")
                        .and_then(|value| value.to_str().ok()),
                    Some("60")
                );
            }
        }
    }

    #[actix_web::test]
    async fn runner_identity_routes_enforce_admin_and_return_secrets_once() {
        let viewer_app =
            test::init_service(App::new().app_data(state(true)).configure(configure)).await;
        let forbidden = test::TestRequest::post()
            .uri("/api/v1/admin/runners/enrollments")
            .insert_header(("authorization", "Bearer viewer-session"))
            .to_request();
        assert_eq!(
            test::call_service(&viewer_app, forbidden).await.status(),
            StatusCode::FORBIDDEN
        );

        let admin_state = state_with_role(true, Role::Administrator);
        let admin_app =
            test::init_service(App::new().app_data(admin_state).configure(configure)).await;
        let create = test::TestRequest::post()
            .uri("/api/v1/admin/runners/enrollments")
            .insert_header(("authorization", "Bearer admin-session"))
            .to_request();
        let created = test::call_service(&admin_app, create).await;
        assert_eq!(created.status(), StatusCode::CREATED);
        assert_eq!(
            created
                .headers()
                .get("cache-control")
                .and_then(|value| value.to_str().ok()),
            Some("no-store")
        );
        let enrollment: serde_json::Value = test::read_body_json(created).await;
        assert!(
            enrollment["token"]
                .as_str()
                .is_some_and(|token| token.starts_with("rbe_"))
        );

        let enroll = test::TestRequest::post()
            .uri("/api/v1/runners/enroll")
            .set_json(serde_json::json!({"token":format!("rbe_{}", "a".repeat(43)), "name":"edge-builder"}))
            .to_request();
        let enrolled = test::call_service(&admin_app, enroll).await;
        assert_eq!(enrolled.status(), StatusCode::CREATED);
        let identity: serde_json::Value = test::read_body_json(enrolled).await;
        let runner_id = identity["runner_id"].as_str().expect("runner id");
        assert!(
            identity["credential"]
                .as_str()
                .is_some_and(|credential| credential.starts_with("rrc_"))
        );

        let fleet = test::TestRequest::get()
            .uri("/api/v1/admin/runners")
            .insert_header(("authorization", "Bearer admin-session"))
            .to_request();
        let fleet_response = test::call_service(&admin_app, fleet).await;
        assert_eq!(fleet_response.status(), StatusCode::OK);
        let fleet_body: serde_json::Value = test::read_body_json(fleet_response).await;
        assert_eq!(fleet_body["runners"][0]["connectivity"], "online");
        assert_eq!(fleet_body["runners"][0]["available_slots"], 1);

        let configure_runner = test::TestRequest::patch()
            .uri(&format!("/api/v1/admin/runners/{runner_id}"))
            .insert_header(("authorization", "Bearer admin-session"))
            .set_json(serde_json::json!({
                "name":"edge-builder-renamed",
                "labels":["linux","arm64"],
                "admin_state":"draining"
            }))
            .to_request();
        assert_eq!(
            test::call_service(&admin_app, configure_runner)
                .await
                .status(),
            StatusCode::NO_CONTENT
        );

        let rotate = test::TestRequest::post()
            .uri(&format!("/api/v1/admin/runners/{runner_id}/rotate"))
            .insert_header(("authorization", "Bearer admin-session"))
            .to_request();
        assert_eq!(
            test::call_service(&admin_app, rotate).await.status(),
            StatusCode::OK
        );
        let revoke = test::TestRequest::delete()
            .uri(&format!("/api/v1/admin/runners/{runner_id}"))
            .insert_header(("authorization", "Bearer admin-session"))
            .to_request();
        assert_eq!(
            test::call_service(&admin_app, revoke).await.status(),
            StatusCode::NO_CONTENT
        );
    }

    #[actix_web::test]
    async fn runner_socket_state_messages_return_durable_acknowledgements() {
        let app_state = state(true);
        let credential = format!("rrc_{}", "a".repeat(43));
        let message_id = Uuid::new_v4().to_string();
        let event = runner_state_message(
            &app_state.control_plane,
            Uuid::new_v4(),
            &credential,
            "attempt_event",
            serde_json::json!({
                "idempotency_token": Uuid::new_v4(),
                "message_id": message_id,
                "sequence": 2,
                "status": "running"
            }),
        )
        .await;
        assert_eq!(event["status"], "ok");
        assert_eq!(event["response"]["message_id"], message_id);
        assert_eq!(event["response"]["acknowledged_sequence"], 2);

        let accepted = runner_state_message(
            &app_state.control_plane,
            Uuid::new_v4(),
            &credential,
            "job_accept",
            serde_json::json!({
                "attempt_id": Uuid::nil(),
                "message_id": Uuid::new_v4().to_string()
            }),
        )
        .await;
        assert_eq!(accepted["status"], "ok");
        assert_eq!(accepted["response"]["acknowledged_sequence"], 1);

        let malformed = runner_state_message(
            &app_state.control_plane,
            Uuid::new_v4(),
            &credential,
            "attempt_event",
            serde_json::json!({"sequence": 0}),
        )
        .await;
        assert_eq!(malformed["status"], "error");
        assert_eq!(malformed["response"]["code"], "invalid_attempt_event");
    }

    #[actix_web::test]
    async fn runner_heartbeat_requires_machine_credentials_and_returns_owned_leases() {
        let app = test::init_service(App::new().app_data(state(true)).configure(configure)).await;
        let socket_without_identity = test::TestRequest::get()
            .uri("/runner/socket/websocket?vsn=2.0.0")
            .to_request();
        assert_eq!(
            test::call_service(&app, socket_without_identity)
                .await
                .status(),
            StatusCode::UNAUTHORIZED
        );
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
            body["pending_offer_attempt_ids"],
            serde_json::json!([Uuid::nil()])
        );
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

        let source_request = test::TestRequest::get()
            .uri(&format!(
                "/api/v1/runners/attempts/{offer_attempt_id}/source"
            ))
            .insert_header(("x-robine-runner-id", Uuid::new_v4().to_string()))
            .insert_header((
                "x-robine-runner-credential",
                format!("rrc_{}", "a".repeat(43)),
            ))
            .to_request();
        let source_response = test::call_service(&app, source_request).await;
        assert_eq!(source_response.status(), StatusCode::OK);
        assert_eq!(
            source_response
                .headers()
                .get("cache-control")
                .and_then(|value| value.to_str().ok()),
            Some("no-store")
        );
        let source_body = test::read_body(source_response).await;
        let source_files =
            robine_source::extract_tar_gz(&source_body, robine_source::ArchiveLimits::default())
                .expect("safe transferred source");
        assert_eq!(source_files[0].path, PathBuf::from("README.md"));
        assert_eq!(source_files[0].contents, b"remote source\n");

        let secrets_request = test::TestRequest::get()
            .uri(&format!(
                "/api/v1/runners/attempts/{offer_attempt_id}/secrets"
            ))
            .insert_header(("x-robine-runner-id", Uuid::new_v4().to_string()))
            .insert_header((
                "x-robine-runner-credential",
                format!("rrc_{}", "a".repeat(43)),
            ))
            .to_request();
        let secrets_response = test::call_service(&app, secrets_request).await;
        assert_eq!(secrets_response.status(), StatusCode::OK);
        assert_eq!(
            secrets_response
                .headers()
                .get("cache-control")
                .and_then(|value| value.to_str().ok()),
            Some("no-store")
        );
        let secrets: serde_json::Value = test::read_body_json(secrets_response).await;
        assert_eq!(secrets, serde_json::json!({"secrets": {}}));

        let log_request = test::TestRequest::post()
            .uri(&format!("/api/v1/runners/attempts/{offer_attempt_id}/logs"))
            .insert_header(("x-robine-runner-id", Uuid::new_v4().to_string()))
            .insert_header((
                "x-robine-runner-credential",
                format!("rrc_{}", "a".repeat(43)),
            ))
            .set_json(serde_json::json!({
                "sequence": 7,
                "step_position": 1,
                "step_name": "Test",
                "stream": "stdout",
                "content": "remote output\n"
            }))
            .to_request();
        let log_response = test::call_service(&app, log_request).await;
        assert_eq!(log_response.status(), StatusCode::OK);
        let acknowledgement: serde_json::Value = test::read_body_json(log_response).await;
        assert_eq!(acknowledgement["sequence"], 7);

        for (decision, expected_sequence) in [("accept", 1), ("reject", 1)] {
            let decision_attempt_id = Uuid::new_v4();
            let message_id = Uuid::new_v4();
            let decision_request = test::TestRequest::post()
                .uri(&format!(
                    "/api/v1/runners/attempts/{decision_attempt_id}/{decision}"
                ))
                .insert_header(("x-robine-runner-id", Uuid::new_v4().to_string()))
                .insert_header((
                    "x-robine-runner-credential",
                    format!("rrc_{}", "a".repeat(43)),
                ))
                .set_json(serde_json::json!({"message_id": message_id}))
                .to_request();
            let response = test::call_service(&app, decision_request).await;
            assert_eq!(response.status(), StatusCode::OK);
            let acknowledgement: serde_json::Value = test::read_body_json(response).await;
            assert_eq!(acknowledgement["message_id"], message_id.to_string());
            assert_eq!(
                acknowledgement["attempt_id"],
                decision_attempt_id.to_string()
            );
            assert_eq!(acknowledgement["acknowledged_sequence"], expected_sequence);
        }
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
