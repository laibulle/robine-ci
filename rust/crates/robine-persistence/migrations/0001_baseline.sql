--
-- PostgreSQL database dump
--


-- Dumped from database version 18.6
-- Dumped by pg_dump version 18.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: oban_job_state; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.oban_job_state AS ENUM (
    'available',
    'suspended',
    'scheduled',
    'executing',
    'retryable',
    'completed',
    'discarded',
    'cancelled'
);


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: artifacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.artifacts (
    id uuid NOT NULL,
    repository_id uuid NOT NULL,
    attempt_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    blob_id character varying(255) NOT NULL,
    digest character varying(255) NOT NULL,
    size bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.artifacts FORCE ROW LEVEL SECURITY;


--
-- Name: attempt_steps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attempt_steps (
    id uuid NOT NULL,
    attempt_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    "position" integer NOT NULL,
    status character varying(255) NOT NULL,
    exit_code integer,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.attempt_steps FORCE ROW LEVEL SECURITY;


--
-- Name: audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events (
    id uuid NOT NULL,
    actor_id character varying(255) NOT NULL,
    action character varying(255) NOT NULL,
    target_type character varying(255) NOT NULL,
    target_id uuid NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    occurred_at timestamp without time zone NOT NULL,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.audit_events FORCE ROW LEVEL SECURITY;


--
-- Name: autoscaling_intents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.autoscaling_intents (
    id uuid NOT NULL,
    policy_id uuid NOT NULL,
    idempotency_key character varying(255) NOT NULL,
    action character varying(255) NOT NULL,
    target_instance_id character varying(255),
    status character varying(255) NOT NULL,
    desired_capacity integer NOT NULL,
    observed_capacity integer NOT NULL,
    last_error character varying(255),
    attempted_at timestamp without time zone,
    completed_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.autoscaling_intents FORCE ROW LEVEL SECURITY;


--
-- Name: autoscaling_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.autoscaling_policies (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    provider character varying(255) NOT NULL,
    runner_template jsonb DEFAULT '{}'::jsonb NOT NULL,
    labels character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    min_runners integer DEFAULT 0 NOT NULL,
    max_runners integer NOT NULL,
    concurrency integer DEFAULT 1 NOT NULL,
    idle_timeout_seconds integer NOT NULL,
    scale_up_cooldown_seconds integer NOT NULL,
    scale_down_cooldown_seconds integer NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.autoscaling_policies FORCE ROW LEVEL SECURITY;


--
-- Name: cache_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cache_entries (
    id uuid NOT NULL,
    repository_id uuid NOT NULL,
    key character varying(512) NOT NULL,
    blob_id character varying(255) NOT NULL,
    digest character varying(255) NOT NULL,
    size bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    last_restored_at timestamp without time zone,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.cache_entries FORCE ROW LEVEL SECURITY;


--
-- Name: ci_tenants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ci_tenants (
    id text NOT NULL,
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: durable_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.durable_jobs (
    id uuid NOT NULL,
    tenant_id character varying(255) DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL,
    source_event_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    payload jsonb NOT NULL,
    status character varying(255) DEFAULT 'available'::character varying NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    available_at timestamp without time zone NOT NULL,
    claimed_at timestamp without time zone,
    claim_token uuid,
    last_error character varying(255),
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT durable_jobs_non_negative_attempts CHECK ((attempts >= 0)),
    CONSTRAINT durable_jobs_status CHECK (((status)::text = ANY ((ARRAY['available'::character varying, 'executing'::character varying, 'retry'::character varying, 'completed'::character varying, 'discarded'::character varying])::text[])))
);

ALTER TABLE ONLY public.durable_jobs FORCE ROW LEVEL SECURITY;


--
-- Name: github_checks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.github_checks (
    id uuid NOT NULL,
    external_key character varying(255) NOT NULL,
    repository_id uuid NOT NULL,
    pipeline_id uuid NOT NULL,
    job_id uuid,
    provider_check_id bigint NOT NULL,
    status character varying(255) NOT NULL,
    conclusion character varying(255),
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    provider character varying(255) DEFAULT 'github'::character varying NOT NULL,
    provider_instance character varying(255) DEFAULT 'default'::character varying NOT NULL,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.github_checks FORCE ROW LEVEL SECURITY;


--
-- Name: github_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.github_deliveries (
    id character varying(255) NOT NULL,
    event character varying(255) NOT NULL,
    payload jsonb NOT NULL,
    status character varying(255) NOT NULL,
    received_at timestamp without time zone NOT NULL,
    processed_at timestamp without time zone,
    failure text,
    provider character varying(255) DEFAULT 'github'::character varying NOT NULL,
    provider_instance character varying(255) DEFAULT 'default'::character varying NOT NULL,
    provider_delivery_id character varying(255) NOT NULL,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.github_deliveries FORCE ROW LEVEL SECURITY;


--
-- Name: github_repositories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.github_repositories (
    id uuid NOT NULL,
    provider_id bigint NOT NULL,
    installation_id bigint NOT NULL,
    owner character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    full_name character varying(255) NOT NULL,
    trusted boolean DEFAULT true NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    provider character varying(255) DEFAULT 'github'::character varying NOT NULL,
    provider_instance character varying(255) DEFAULT 'default'::character varying NOT NULL,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.github_repositories FORCE ROW LEVEL SECURITY;


--
-- Name: job_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.job_attempts (
    id uuid NOT NULL,
    job_id uuid NOT NULL,
    number integer NOT NULL,
    idempotency_token uuid NOT NULL,
    status character varying(255) NOT NULL,
    lease_expires_at timestamp without time zone NOT NULL,
    last_sequence integer DEFAULT 0 NOT NULL,
    result_reason character varying(255),
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    runner_id character varying(255),
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.job_attempts FORCE ROW LEVEL SECURITY;


--
-- Name: local_credentials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.local_credentials (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    password_hash text NOT NULL,
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: log_chunks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.log_chunks (
    id uuid NOT NULL,
    attempt_id uuid NOT NULL,
    sequence bigint NOT NULL,
    step_position integer NOT NULL,
    step_name character varying(255) NOT NULL,
    step_status character varying(255) NOT NULL,
    exit_code integer,
    duration_ms integer NOT NULL,
    content text NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    phase character varying(255) DEFAULT 'execution'::character varying NOT NULL,
    stream character varying(255) DEFAULT 'combined'::character varying NOT NULL,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.log_chunks FORCE ROW LEVEL SECURITY;


--
-- Name: oban_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oban_jobs (
    id bigint NOT NULL,
    state public.oban_job_state DEFAULT 'available'::public.oban_job_state NOT NULL,
    queue text DEFAULT 'default'::text NOT NULL,
    worker text NOT NULL,
    args jsonb DEFAULT '{}'::jsonb NOT NULL,
    errors jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    attempt integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 20 NOT NULL,
    inserted_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    scheduled_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    attempted_at timestamp without time zone,
    completed_at timestamp without time zone,
    attempted_by text[],
    discarded_at timestamp without time zone,
    priority integer DEFAULT 0 NOT NULL,
    tags text[] DEFAULT ARRAY[]::text[],
    meta jsonb DEFAULT '{}'::jsonb,
    cancelled_at timestamp without time zone,
    CONSTRAINT attempt_range CHECK (((attempt >= 0) AND (attempt <= max_attempts))),
    CONSTRAINT positive_max_attempts CHECK ((max_attempts > 0)),
    CONSTRAINT queue_length CHECK (((char_length(queue) > 0) AND (char_length(queue) < 128))),
    CONSTRAINT worker_length CHECK (((char_length(worker) > 0) AND (char_length(worker) < 128)))
);


--
-- Name: TABLE oban_jobs; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.oban_jobs IS '14';


--
-- Name: oban_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.oban_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: oban_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.oban_jobs_id_seq OWNED BY public.oban_jobs.id;


--
-- Name: oban_peers; Type: TABLE; Schema: public; Owner: -
--

CREATE UNLOGGED TABLE public.oban_peers (
    name text NOT NULL,
    node text NOT NULL,
    started_at timestamp without time zone NOT NULL,
    expires_at timestamp without time zone NOT NULL
);


--
-- Name: oidc_identities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oidc_identities (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    issuer character varying(255) NOT NULL,
    subject character varying(255) NOT NULL,
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: outbox_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.outbox_events (
    id uuid NOT NULL,
    event_type character varying(255) NOT NULL,
    aggregate_id uuid NOT NULL,
    payload jsonb NOT NULL,
    occurred_at timestamp without time zone NOT NULL,
    delivered_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL,
    delivery_attempts integer DEFAULT 0 NOT NULL,
    available_at timestamp without time zone DEFAULT timezone('UTC'::text, now()),
    last_error character varying(255),
    dead_lettered_at timestamp without time zone
);

ALTER TABLE ONLY public.outbox_events FORCE ROW LEVEL SECURITY;


--
-- Name: pipeline_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pipeline_jobs (
    id uuid NOT NULL,
    pipeline_id uuid NOT NULL,
    job_key character varying(255) NOT NULL,
    status character varying(255) NOT NULL,
    needs character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    "position" integer NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    execution_spec jsonb DEFAULT '{}'::jsonb NOT NULL,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.pipeline_jobs FORCE ROW LEVEL SECURITY;


--
-- Name: pipelines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pipelines (
    id uuid NOT NULL,
    repository_id uuid NOT NULL,
    workflow_name character varying(255) NOT NULL,
    commit_sha character varying(40) NOT NULL,
    status character varying(255) NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    trigger character varying(255) DEFAULT 'manual'::character varying NOT NULL,
    actor character varying(255) DEFAULT 'system'::character varying NOT NULL,
    started_at timestamp without time zone,
    finished_at timestamp without time zone,
    correlation_id character varying(255) DEFAULT 'legacy'::character varying NOT NULL,
    inputs jsonb DEFAULT '{}'::jsonb NOT NULL,
    scheduled_for timestamp without time zone,
    source_ref character varying(255),
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.pipelines FORCE ROW LEVEL SECURITY;


--
-- Name: remote_runners; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.remote_runners (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    admin_state character varying(255) DEFAULT 'enabled'::character varying NOT NULL,
    protocol_version integer,
    software_version character varying(255),
    capabilities jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_authenticated_at timestamp without time zone,
    last_seen_at timestamp without time zone,
    revoked_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    labels character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL,
    CONSTRAINT remote_runners_admin_state CHECK (((admin_state)::text = ANY ((ARRAY['enabled'::character varying, 'draining'::character varying, 'revoked'::character varying])::text[])))
);

ALTER TABLE ONLY public.remote_runners FORCE ROW LEVEL SECURITY;


--
-- Name: runner_attempt_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.runner_attempt_events (
    id uuid NOT NULL,
    runner_id character varying(255) NOT NULL,
    message_id character varying(255) NOT NULL,
    attempt_id uuid NOT NULL,
    sequence integer NOT NULL,
    status character varying(255) NOT NULL,
    reason character varying(255),
    inserted_at timestamp without time zone NOT NULL,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL,
    CONSTRAINT runner_attempt_events_positive_sequence CHECK ((sequence > 0))
);

ALTER TABLE ONLY public.runner_attempt_events FORCE ROW LEVEL SECURITY;


--
-- Name: runner_credentials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.runner_credentials (
    id uuid NOT NULL,
    runner_id uuid NOT NULL,
    credential_digest bytea NOT NULL,
    expires_at timestamp without time zone,
    revoked_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.runner_credentials FORCE ROW LEVEL SECURITY;


--
-- Name: runner_enrollment_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.runner_enrollment_tokens (
    id uuid NOT NULL,
    token_digest bytea NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    consumed_at timestamp without time zone,
    created_by character varying(255) NOT NULL,
    runner_id uuid,
    inserted_at timestamp without time zone NOT NULL,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.runner_enrollment_tokens FORCE ROW LEVEL SECURITY;


--
-- Name: schedule_reconciliation_states; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schedule_reconciliation_states (
    key character varying(255) NOT NULL,
    cursor timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    last_attempt_at timestamp without time zone,
    last_success_at timestamp without time zone,
    last_failure character varying(255),
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.schedule_reconciliation_states FORCE ROW LEVEL SECURITY;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: secrets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.secrets (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    scope character varying(255) NOT NULL,
    repository_id uuid,
    allowed_repository_ids uuid[] DEFAULT ARRAY[]::uuid[] NOT NULL,
    ciphertext bytea NOT NULL,
    nonce bytea NOT NULL,
    tag bytea NOT NULL,
    key_version integer NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.secrets FORCE ROW LEVEL SECURITY;


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    token_digest bytea NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    revoked_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: storage_backend_states; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.storage_backend_states (
    id character varying(255) NOT NULL,
    backend character varying(255) NOT NULL,
    namespace_digest character varying(255) NOT NULL,
    acknowledged_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.storage_backend_states FORCE ROW LEVEL SECURITY;


--
-- Name: storage_gc_candidates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.storage_gc_candidates (
    blob_id character varying(255) NOT NULL,
    not_before timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.storage_gc_candidates FORCE ROW LEVEL SECURITY;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid NOT NULL,
    email character varying(255) NOT NULL,
    role character varying(255) NOT NULL,
    disabled boolean DEFAULT false NOT NULL,
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: workflow_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.workflow_revisions (
    id uuid NOT NULL,
    pipeline_id uuid NOT NULL,
    path character varying(255) NOT NULL,
    source text NOT NULL,
    digest character varying(64) NOT NULL,
    normalized_graph jsonb NOT NULL,
    created_at timestamp without time zone NOT NULL,
    included_sources jsonb DEFAULT '{}'::jsonb NOT NULL,
    tenant_id text DEFAULT COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text) NOT NULL
);

ALTER TABLE ONLY public.workflow_revisions FORCE ROW LEVEL SECURITY;


--
-- Name: oban_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_jobs ALTER COLUMN id SET DEFAULT nextval('public.oban_jobs_id_seq'::regclass);


--
-- Name: artifacts artifacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.artifacts
    ADD CONSTRAINT artifacts_pkey PRIMARY KEY (id);


--
-- Name: attempt_steps attempt_steps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attempt_steps
    ADD CONSTRAINT attempt_steps_pkey PRIMARY KEY (id);


--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_pkey PRIMARY KEY (id);


--
-- Name: autoscaling_intents autoscaling_intents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.autoscaling_intents
    ADD CONSTRAINT autoscaling_intents_pkey PRIMARY KEY (id);


--
-- Name: autoscaling_policies autoscaling_policies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.autoscaling_policies
    ADD CONSTRAINT autoscaling_policies_pkey PRIMARY KEY (id);


--
-- Name: cache_entries cache_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cache_entries
    ADD CONSTRAINT cache_entries_pkey PRIMARY KEY (id);


--
-- Name: ci_tenants ci_tenants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ci_tenants
    ADD CONSTRAINT ci_tenants_pkey PRIMARY KEY (id);


--
-- Name: durable_jobs durable_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.durable_jobs
    ADD CONSTRAINT durable_jobs_pkey PRIMARY KEY (id);


--
-- Name: github_checks github_checks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.github_checks
    ADD CONSTRAINT github_checks_pkey PRIMARY KEY (id);


--
-- Name: github_deliveries github_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.github_deliveries
    ADD CONSTRAINT github_deliveries_pkey PRIMARY KEY (id);


--
-- Name: github_repositories github_repositories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.github_repositories
    ADD CONSTRAINT github_repositories_pkey PRIMARY KEY (id);


--
-- Name: job_attempts job_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_attempts
    ADD CONSTRAINT job_attempts_pkey PRIMARY KEY (id);


--
-- Name: local_credentials local_credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.local_credentials
    ADD CONSTRAINT local_credentials_pkey PRIMARY KEY (id);


--
-- Name: log_chunks log_chunks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.log_chunks
    ADD CONSTRAINT log_chunks_pkey PRIMARY KEY (id);


--
-- Name: oban_jobs non_negative_priority; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.oban_jobs
    ADD CONSTRAINT non_negative_priority CHECK ((priority >= 0)) NOT VALID;


--
-- Name: oban_jobs oban_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_jobs
    ADD CONSTRAINT oban_jobs_pkey PRIMARY KEY (id);


--
-- Name: oban_peers oban_peers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_peers
    ADD CONSTRAINT oban_peers_pkey PRIMARY KEY (name);


--
-- Name: oidc_identities oidc_identities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oidc_identities
    ADD CONSTRAINT oidc_identities_pkey PRIMARY KEY (id);


--
-- Name: outbox_events outbox_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.outbox_events
    ADD CONSTRAINT outbox_events_pkey PRIMARY KEY (id);


--
-- Name: pipeline_jobs pipeline_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_jobs
    ADD CONSTRAINT pipeline_jobs_pkey PRIMARY KEY (id);


--
-- Name: pipelines pipelines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipelines
    ADD CONSTRAINT pipelines_pkey PRIMARY KEY (id);


--
-- Name: remote_runners remote_runners_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.remote_runners
    ADD CONSTRAINT remote_runners_pkey PRIMARY KEY (id);


--
-- Name: runner_attempt_events runner_attempt_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runner_attempt_events
    ADD CONSTRAINT runner_attempt_events_pkey PRIMARY KEY (id);


--
-- Name: runner_credentials runner_credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runner_credentials
    ADD CONSTRAINT runner_credentials_pkey PRIMARY KEY (id);


--
-- Name: runner_enrollment_tokens runner_enrollment_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runner_enrollment_tokens
    ADD CONSTRAINT runner_enrollment_tokens_pkey PRIMARY KEY (id);


--
-- Name: schedule_reconciliation_states schedule_reconciliation_states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_reconciliation_states
    ADD CONSTRAINT schedule_reconciliation_states_pkey PRIMARY KEY (tenant_id, key);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: secrets secrets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.secrets
    ADD CONSTRAINT secrets_pkey PRIMARY KEY (id);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: storage_backend_states storage_backend_states_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.storage_backend_states
    ADD CONSTRAINT storage_backend_states_pkey PRIMARY KEY (tenant_id, id);


--
-- Name: storage_gc_candidates storage_gc_candidates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.storage_gc_candidates
    ADD CONSTRAINT storage_gc_candidates_pkey PRIMARY KEY (tenant_id, blob_id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: workflow_revisions workflow_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_revisions
    ADD CONSTRAINT workflow_revisions_pkey PRIMARY KEY (id);


--
-- Name: artifacts_attempt_id_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX artifacts_attempt_id_name_index ON public.artifacts USING btree (tenant_id, attempt_id, name);


--
-- Name: artifacts_repository_id_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX artifacts_repository_id_expires_at_index ON public.artifacts USING btree (repository_id, expires_at);


--
-- Name: artifacts_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX artifacts_tenant_id_index ON public.artifacts USING btree (tenant_id);


--
-- Name: attempt_steps_attempt_id_position_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX attempt_steps_attempt_id_position_index ON public.attempt_steps USING btree (tenant_id, attempt_id, "position");


--
-- Name: attempt_steps_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX attempt_steps_tenant_id_index ON public.attempt_steps USING btree (tenant_id);


--
-- Name: audit_events_target_type_target_id_occurred_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_target_type_target_id_occurred_at_index ON public.audit_events USING btree (target_type, target_id, occurred_at);


--
-- Name: audit_events_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_events_tenant_id_index ON public.audit_events USING btree (tenant_id);


--
-- Name: autoscaling_intents_idempotency_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX autoscaling_intents_idempotency_key_index ON public.autoscaling_intents USING btree (tenant_id, idempotency_key);


--
-- Name: autoscaling_intents_policy_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX autoscaling_intents_policy_id_status_index ON public.autoscaling_intents USING btree (policy_id, status);


--
-- Name: autoscaling_intents_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX autoscaling_intents_tenant_id_index ON public.autoscaling_intents USING btree (tenant_id);


--
-- Name: autoscaling_policies_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX autoscaling_policies_name_index ON public.autoscaling_policies USING btree (tenant_id, name);


--
-- Name: autoscaling_policies_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX autoscaling_policies_tenant_id_index ON public.autoscaling_policies USING btree (tenant_id);


--
-- Name: cache_entries_expires_at_last_restored_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cache_entries_expires_at_last_restored_at_index ON public.cache_entries USING btree (expires_at, last_restored_at);


--
-- Name: cache_entries_repository_id_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX cache_entries_repository_id_key_index ON public.cache_entries USING btree (tenant_id, repository_id, key);


--
-- Name: cache_entries_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cache_entries_tenant_id_index ON public.cache_entries USING btree (tenant_id);


--
-- Name: ci_tenants_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ci_tenants_inserted_at_index ON public.ci_tenants USING btree (inserted_at);


--
-- Name: durable_jobs_tenant_id_source_event_id_kind_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX durable_jobs_tenant_id_source_event_id_kind_index ON public.durable_jobs USING btree (tenant_id, source_event_id, kind);


--
-- Name: durable_jobs_tenant_id_status_available_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX durable_jobs_tenant_id_status_available_at_index ON public.durable_jobs USING btree (tenant_id, status, available_at) WHERE ((status)::text = ANY ((ARRAY['available'::character varying, 'retry'::character varying])::text[]));


--
-- Name: github_checks_pipeline_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX github_checks_pipeline_id_index ON public.github_checks USING btree (pipeline_id);


--
-- Name: github_checks_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX github_checks_tenant_id_index ON public.github_checks USING btree (tenant_id);


--
-- Name: github_deliveries_status_received_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX github_deliveries_status_received_at_index ON public.github_deliveries USING btree (status, received_at);


--
-- Name: github_deliveries_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX github_deliveries_tenant_id_index ON public.github_deliveries USING btree (tenant_id);


--
-- Name: github_repositories_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX github_repositories_tenant_id_index ON public.github_repositories USING btree (tenant_id);


--
-- Name: job_attempts_idempotency_token_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX job_attempts_idempotency_token_index ON public.job_attempts USING btree (tenant_id, idempotency_token);


--
-- Name: job_attempts_job_id_number_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX job_attempts_job_id_number_index ON public.job_attempts USING btree (tenant_id, job_id, number);


--
-- Name: job_attempts_runner_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_attempts_runner_id_index ON public.job_attempts USING btree (runner_id) WHERE (runner_id IS NOT NULL);


--
-- Name: job_attempts_status_lease_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_attempts_status_lease_expires_at_index ON public.job_attempts USING btree (status, lease_expires_at);


--
-- Name: job_attempts_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX job_attempts_tenant_id_index ON public.job_attempts USING btree (tenant_id);


--
-- Name: local_credentials_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX local_credentials_user_id_index ON public.local_credentials USING btree (user_id);


--
-- Name: log_chunks_attempt_id_phase_step_position_sequence_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX log_chunks_attempt_id_phase_step_position_sequence_index ON public.log_chunks USING btree (attempt_id, phase, step_position, sequence);


--
-- Name: log_chunks_attempt_id_sequence_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX log_chunks_attempt_id_sequence_index ON public.log_chunks USING btree (tenant_id, attempt_id, sequence);


--
-- Name: log_chunks_attempt_id_step_position_sequence_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX log_chunks_attempt_id_step_position_sequence_index ON public.log_chunks USING btree (attempt_id, step_position, sequence);


--
-- Name: log_chunks_attempt_id_stream_sequence_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX log_chunks_attempt_id_stream_sequence_index ON public.log_chunks USING btree (attempt_id, stream, sequence);


--
-- Name: log_chunks_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX log_chunks_inserted_at_index ON public.log_chunks USING btree (inserted_at);


--
-- Name: log_chunks_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX log_chunks_tenant_id_index ON public.log_chunks USING btree (tenant_id);


--
-- Name: oban_jobs_args_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_args_index ON public.oban_jobs USING gin (args);


--
-- Name: oban_jobs_meta_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_meta_index ON public.oban_jobs USING gin (meta);


--
-- Name: oban_jobs_state_cancelled_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_state_cancelled_at_index ON public.oban_jobs USING btree (state, cancelled_at);


--
-- Name: oban_jobs_state_discarded_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_state_discarded_at_index ON public.oban_jobs USING btree (state, discarded_at);


--
-- Name: oban_jobs_state_queue_priority_scheduled_at_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_state_queue_priority_scheduled_at_id_index ON public.oban_jobs USING btree (state, queue, priority, scheduled_at, id);


--
-- Name: oidc_identities_issuer_subject_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX oidc_identities_issuer_subject_index ON public.oidc_identities USING btree (issuer, subject);


--
-- Name: oidc_identities_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oidc_identities_user_id_index ON public.oidc_identities USING btree (user_id);


--
-- Name: outbox_events_aggregate_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX outbox_events_aggregate_id_index ON public.outbox_events USING btree (aggregate_id);


--
-- Name: outbox_events_available_at_occurred_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX outbox_events_available_at_occurred_at_index ON public.outbox_events USING btree (available_at, occurred_at) WHERE ((delivered_at IS NULL) AND (dead_lettered_at IS NULL));


--
-- Name: outbox_events_delivered_at_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX outbox_events_delivered_at_inserted_at_index ON public.outbox_events USING btree (delivered_at, inserted_at);


--
-- Name: outbox_events_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX outbox_events_tenant_id_index ON public.outbox_events USING btree (tenant_id);


--
-- Name: pipeline_jobs_pipeline_id_job_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pipeline_jobs_pipeline_id_job_key_index ON public.pipeline_jobs USING btree (tenant_id, pipeline_id, job_key);


--
-- Name: pipeline_jobs_status_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_jobs_status_inserted_at_index ON public.pipeline_jobs USING btree (status, inserted_at);


--
-- Name: pipeline_jobs_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipeline_jobs_tenant_id_index ON public.pipeline_jobs USING btree (tenant_id);


--
-- Name: pipelines_repository_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipelines_repository_id_inserted_at_index ON public.pipelines USING btree (repository_id, inserted_at);


--
-- Name: pipelines_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipelines_tenant_id_index ON public.pipelines USING btree (tenant_id);


--
-- Name: pipelines_trigger_scheduled_for_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pipelines_trigger_scheduled_for_index ON public.pipelines USING btree (trigger, scheduled_for);


--
-- Name: remote_runners_admin_state_last_seen_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX remote_runners_admin_state_last_seen_at_index ON public.remote_runners USING btree (admin_state, last_seen_at);


--
-- Name: remote_runners_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX remote_runners_tenant_id_index ON public.remote_runners USING btree (tenant_id);


--
-- Name: runner_attempt_events_attempt_id_sequence_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX runner_attempt_events_attempt_id_sequence_index ON public.runner_attempt_events USING btree (tenant_id, attempt_id, sequence);


--
-- Name: runner_attempt_events_runner_id_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX runner_attempt_events_runner_id_message_id_index ON public.runner_attempt_events USING btree (tenant_id, runner_id, message_id);


--
-- Name: runner_attempt_events_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX runner_attempt_events_tenant_id_index ON public.runner_attempt_events USING btree (tenant_id);


--
-- Name: runner_credentials_credential_digest_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX runner_credentials_credential_digest_index ON public.runner_credentials USING btree (tenant_id, credential_digest);


--
-- Name: runner_credentials_runner_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX runner_credentials_runner_id_index ON public.runner_credentials USING btree (runner_id) WHERE (revoked_at IS NULL);


--
-- Name: runner_credentials_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX runner_credentials_tenant_id_index ON public.runner_credentials USING btree (tenant_id);


--
-- Name: runner_enrollment_tokens_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX runner_enrollment_tokens_expires_at_index ON public.runner_enrollment_tokens USING btree (expires_at) WHERE (consumed_at IS NULL);


--
-- Name: runner_enrollment_tokens_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX runner_enrollment_tokens_tenant_id_index ON public.runner_enrollment_tokens USING btree (tenant_id);


--
-- Name: runner_enrollment_tokens_token_digest_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX runner_enrollment_tokens_token_digest_index ON public.runner_enrollment_tokens USING btree (tenant_id, token_digest);


--
-- Name: schedule_reconciliation_states_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX schedule_reconciliation_states_tenant_id_index ON public.schedule_reconciliation_states USING btree (tenant_id);


--
-- Name: secrets_scope_repository_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX secrets_scope_repository_name_index ON public.secrets USING btree (tenant_id, scope, repository_id, name) NULLS NOT DISTINCT;


--
-- Name: secrets_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX secrets_tenant_id_index ON public.secrets USING btree (tenant_id);


--
-- Name: sessions_token_digest_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX sessions_token_digest_index ON public.sessions USING btree (token_digest);


--
-- Name: sessions_user_id_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sessions_user_id_expires_at_index ON public.sessions USING btree (user_id, expires_at);


--
-- Name: source_control_deliveries_provider_identity_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX source_control_deliveries_provider_identity_index ON public.github_deliveries USING btree (tenant_id, provider, provider_instance, provider_delivery_id);


--
-- Name: source_control_repositories_provider_identity_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX source_control_repositories_provider_identity_index ON public.github_repositories USING btree (tenant_id, provider, provider_instance, provider_id);


--
-- Name: source_control_repositories_provider_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX source_control_repositories_provider_name_index ON public.github_repositories USING btree (tenant_id, provider, provider_instance, full_name);


--
-- Name: source_control_statuses_provider_external_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX source_control_statuses_provider_external_key_index ON public.github_checks USING btree (tenant_id, provider, provider_instance, external_key);


--
-- Name: storage_backend_states_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX storage_backend_states_tenant_id_index ON public.storage_backend_states USING btree (tenant_id);


--
-- Name: storage_gc_candidates_not_before_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX storage_gc_candidates_not_before_index ON public.storage_gc_candidates USING btree (not_before);


--
-- Name: storage_gc_candidates_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX storage_gc_candidates_tenant_id_index ON public.storage_gc_candidates USING btree (tenant_id);


--
-- Name: users_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_email_index ON public.users USING btree (email);


--
-- Name: workflow_revisions_digest_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX workflow_revisions_digest_index ON public.workflow_revisions USING btree (digest);


--
-- Name: workflow_revisions_pipeline_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX workflow_revisions_pipeline_id_index ON public.workflow_revisions USING btree (tenant_id, pipeline_id);


--
-- Name: workflow_revisions_tenant_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX workflow_revisions_tenant_id_index ON public.workflow_revisions USING btree (tenant_id);


--
-- Name: attempt_steps attempt_steps_attempt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attempt_steps
    ADD CONSTRAINT attempt_steps_attempt_id_fkey FOREIGN KEY (attempt_id) REFERENCES public.job_attempts(id) ON DELETE CASCADE;


--
-- Name: autoscaling_intents autoscaling_intents_policy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.autoscaling_intents
    ADD CONSTRAINT autoscaling_intents_policy_id_fkey FOREIGN KEY (policy_id) REFERENCES public.autoscaling_policies(id) ON DELETE CASCADE;


--
-- Name: job_attempts job_attempts_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.job_attempts
    ADD CONSTRAINT job_attempts_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.pipeline_jobs(id) ON DELETE CASCADE;


--
-- Name: local_credentials local_credentials_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.local_credentials
    ADD CONSTRAINT local_credentials_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: log_chunks log_chunks_attempt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.log_chunks
    ADD CONSTRAINT log_chunks_attempt_id_fkey FOREIGN KEY (attempt_id) REFERENCES public.job_attempts(id) ON DELETE CASCADE;


--
-- Name: oidc_identities oidc_identities_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oidc_identities
    ADD CONSTRAINT oidc_identities_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: pipeline_jobs pipeline_jobs_pipeline_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_jobs
    ADD CONSTRAINT pipeline_jobs_pipeline_id_fkey FOREIGN KEY (pipeline_id) REFERENCES public.pipelines(id) ON DELETE CASCADE;


--
-- Name: runner_attempt_events runner_attempt_events_attempt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runner_attempt_events
    ADD CONSTRAINT runner_attempt_events_attempt_id_fkey FOREIGN KEY (attempt_id) REFERENCES public.job_attempts(id) ON DELETE CASCADE;


--
-- Name: runner_credentials runner_credentials_runner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runner_credentials
    ADD CONSTRAINT runner_credentials_runner_id_fkey FOREIGN KEY (runner_id) REFERENCES public.remote_runners(id) ON DELETE CASCADE;


--
-- Name: runner_enrollment_tokens runner_enrollment_tokens_runner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runner_enrollment_tokens
    ADD CONSTRAINT runner_enrollment_tokens_runner_id_fkey FOREIGN KEY (runner_id) REFERENCES public.remote_runners(id) ON DELETE SET NULL;


--
-- Name: sessions sessions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: workflow_revisions workflow_revisions_pipeline_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.workflow_revisions
    ADD CONSTRAINT workflow_revisions_pipeline_id_fkey FOREIGN KEY (pipeline_id) REFERENCES public.pipelines(id) ON DELETE CASCADE;


--
-- Name: artifacts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.artifacts ENABLE ROW LEVEL SECURITY;

--
-- Name: artifacts artifacts_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY artifacts_tenant_isolation ON public.artifacts USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: attempt_steps; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.attempt_steps ENABLE ROW LEVEL SECURITY;

--
-- Name: attempt_steps attempt_steps_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY attempt_steps_tenant_isolation ON public.attempt_steps USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: audit_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.audit_events ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_events audit_events_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY audit_events_tenant_isolation ON public.audit_events USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: autoscaling_intents; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.autoscaling_intents ENABLE ROW LEVEL SECURITY;

--
-- Name: autoscaling_intents autoscaling_intents_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY autoscaling_intents_tenant_isolation ON public.autoscaling_intents USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: autoscaling_policies; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.autoscaling_policies ENABLE ROW LEVEL SECURITY;

--
-- Name: autoscaling_policies autoscaling_policies_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY autoscaling_policies_tenant_isolation ON public.autoscaling_policies USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: cache_entries; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.cache_entries ENABLE ROW LEVEL SECURITY;

--
-- Name: cache_entries cache_entries_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY cache_entries_tenant_isolation ON public.cache_entries USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: durable_jobs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.durable_jobs ENABLE ROW LEVEL SECURITY;

--
-- Name: durable_jobs durable_jobs_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY durable_jobs_tenant_isolation ON public.durable_jobs USING (((tenant_id)::text = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK (((tenant_id)::text = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: github_checks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.github_checks ENABLE ROW LEVEL SECURITY;

--
-- Name: github_checks github_checks_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY github_checks_tenant_isolation ON public.github_checks USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: github_deliveries; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.github_deliveries ENABLE ROW LEVEL SECURITY;

--
-- Name: github_deliveries github_deliveries_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY github_deliveries_tenant_isolation ON public.github_deliveries USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: github_repositories; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.github_repositories ENABLE ROW LEVEL SECURITY;

--
-- Name: github_repositories github_repositories_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY github_repositories_tenant_isolation ON public.github_repositories USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: job_attempts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.job_attempts ENABLE ROW LEVEL SECURITY;

--
-- Name: job_attempts job_attempts_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY job_attempts_tenant_isolation ON public.job_attempts USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: log_chunks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.log_chunks ENABLE ROW LEVEL SECURITY;

--
-- Name: log_chunks log_chunks_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY log_chunks_tenant_isolation ON public.log_chunks USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: outbox_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.outbox_events ENABLE ROW LEVEL SECURITY;

--
-- Name: outbox_events outbox_events_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY outbox_events_tenant_isolation ON public.outbox_events USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: pipeline_jobs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pipeline_jobs ENABLE ROW LEVEL SECURITY;

--
-- Name: pipeline_jobs pipeline_jobs_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pipeline_jobs_tenant_isolation ON public.pipeline_jobs USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: pipelines; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pipelines ENABLE ROW LEVEL SECURITY;

--
-- Name: pipelines pipelines_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pipelines_tenant_isolation ON public.pipelines USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: remote_runners; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.remote_runners ENABLE ROW LEVEL SECURITY;

--
-- Name: remote_runners remote_runners_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY remote_runners_tenant_isolation ON public.remote_runners USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: runner_attempt_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.runner_attempt_events ENABLE ROW LEVEL SECURITY;

--
-- Name: runner_attempt_events runner_attempt_events_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY runner_attempt_events_tenant_isolation ON public.runner_attempt_events USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: runner_credentials; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.runner_credentials ENABLE ROW LEVEL SECURITY;

--
-- Name: runner_credentials runner_credentials_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY runner_credentials_tenant_isolation ON public.runner_credentials USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: runner_enrollment_tokens; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.runner_enrollment_tokens ENABLE ROW LEVEL SECURITY;

--
-- Name: runner_enrollment_tokens runner_enrollment_tokens_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY runner_enrollment_tokens_tenant_isolation ON public.runner_enrollment_tokens USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: schedule_reconciliation_states; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.schedule_reconciliation_states ENABLE ROW LEVEL SECURITY;

--
-- Name: schedule_reconciliation_states schedule_reconciliation_states_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY schedule_reconciliation_states_tenant_isolation ON public.schedule_reconciliation_states USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: secrets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.secrets ENABLE ROW LEVEL SECURITY;

--
-- Name: secrets secrets_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY secrets_tenant_isolation ON public.secrets USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: storage_backend_states; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.storage_backend_states ENABLE ROW LEVEL SECURITY;

--
-- Name: storage_backend_states storage_backend_states_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY storage_backend_states_tenant_isolation ON public.storage_backend_states USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: storage_gc_candidates; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.storage_gc_candidates ENABLE ROW LEVEL SECURITY;

--
-- Name: storage_gc_candidates storage_gc_candidates_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY storage_gc_candidates_tenant_isolation ON public.storage_gc_candidates USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- Name: workflow_revisions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.workflow_revisions ENABLE ROW LEVEL SECURITY;

--
-- Name: workflow_revisions workflow_revisions_tenant_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY workflow_revisions_tenant_isolation ON public.workflow_revisions USING ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text))) WITH CHECK ((tenant_id = COALESCE(NULLIF(current_setting('robine.tenant_id'::text, true), ''::text), 'standalone'::text)));


--
-- PostgreSQL database dump complete
--

