ALTER TABLE public.schedule_reconciliation_states
  ADD COLUMN IF NOT EXISTS last_duration_ms bigint,
  ADD COLUMN IF NOT EXISTS last_outcome character varying(32),
  ADD COLUMN IF NOT EXISTS last_scanned_minutes integer,
  ADD COLUMN IF NOT EXISTS last_due_occurrences integer,
  ADD COLUMN IF NOT EXISTS last_pipeline_count integer,
  ADD COLUMN IF NOT EXISTS last_truncated_minutes bigint;
