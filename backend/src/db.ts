import pg from "pg";
import { config } from "./config.js";

export const pool = new pg.Pool({
  connectionString: config.databaseUrl,
  max: 10,
  ssl: config.databaseUrl.includes("railway") || config.databaseUrl.includes("sslmode")
    ? { rejectUnauthorized: false }
    : undefined,
});

export async function query<T extends pg.QueryResultRow = pg.QueryResultRow>(
  text: string,
  params?: unknown[],
): Promise<pg.QueryResult<T>> {
  return pool.query<T>(text, params as never);
}

const SCHEMA = `
CREATE TABLE IF NOT EXISTS oura_tokens (
  id INT PRIMARY KEY DEFAULT 1,
  access_token TEXT NOT NULL,
  refresh_token TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (id = 1)
);

-- Raw documents from Oura, keyed by type + Oura's document id.
CREATE TABLE IF NOT EXISTS oura_documents (
  data_type TEXT NOT NULL,
  doc_id TEXT NOT NULL,
  day DATE,
  payload JSONB NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (data_type, doc_id)
);
CREATE INDEX IF NOT EXISTS idx_oura_documents_day ON oura_documents (data_type, day);

-- Unified daily timeline: one row per (day, source, metric).
CREATE TABLE IF NOT EXISTS metrics (
  day DATE NOT NULL,
  source TEXT NOT NULL,
  metric TEXT NOT NULL,
  value DOUBLE PRECISION,
  meta JSONB,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (day, source, metric)
);
CREATE INDEX IF NOT EXISTS idx_metrics_metric ON metrics (metric, day);

-- High-frequency samples (intraday heart rate, HRV, etc).
CREATE TABLE IF NOT EXISTS samples (
  ts TIMESTAMPTZ NOT NULL,
  source TEXT NOT NULL,
  metric TEXT NOT NULL,
  value DOUBLE PRECISION NOT NULL,
  meta JSONB,
  PRIMARY KEY (ts, source, metric)
);
CREATE INDEX IF NOT EXISTS idx_samples_metric_ts ON samples (metric, ts);

-- Calendar events pushed from the phone.
CREATE TABLE IF NOT EXISTS calendar_events (
  event_id TEXT PRIMARY KEY,
  title TEXT,
  starts_at TIMESTAMPTZ NOT NULL,
  ends_at TIMESTAMPTZ NOT NULL,
  is_all_day BOOLEAN NOT NULL DEFAULT false,
  meta JSONB,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_calendar_starts ON calendar_events (starts_at);

-- Agent long-term memory.
CREATE TABLE IF NOT EXISTS agent_memory (
  id BIGSERIAL PRIMARY KEY,
  category TEXT NOT NULL,           -- pattern | preference | outcome | observation
  content TEXT NOT NULL,
  importance INT NOT NULL DEFAULT 5, -- 1..10
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  archived BOOLEAN NOT NULL DEFAULT false
);

-- Agent outputs (briefings, wind-downs, weekly reports) + chat history.
CREATE TABLE IF NOT EXISTS agent_messages (
  id BIGSERIAL PRIMARY KEY,
  kind TEXT NOT NULL,               -- briefing | winddown | weekly | chat_user | chat_assistant | insight
  content TEXT NOT NULL,
  meta JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_agent_messages_kind ON agent_messages (kind, created_at DESC);

-- n=1 experiments.
CREATE TABLE IF NOT EXISTS experiments (
  id BIGSERIAL PRIMARY KEY,
  hypothesis TEXT NOT NULL,
  intervention TEXT NOT NULL,        -- human description of what to do
  target_metric TEXT NOT NULL,       -- metric name in metrics table
  baseline_start DATE NOT NULL,
  baseline_end DATE NOT NULL,
  start_day DATE NOT NULL,
  end_day DATE NOT NULL,
  status TEXT NOT NULL DEFAULT 'proposed',  -- proposed | active | completed | abandoned
  result JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS experiment_logs (
  experiment_id BIGINT NOT NULL REFERENCES experiments(id),
  day DATE NOT NULL,
  complied BOOLEAN,
  note TEXT,
  PRIMARY KEY (experiment_id, day)
);

-- Device push tokens.
CREATE TABLE IF NOT EXISTS devices (
  token TEXT PRIMARY KEY,
  platform TEXT NOT NULL DEFAULT 'ios',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Scheduled pushes the agent has queued.
CREATE TABLE IF NOT EXISTS scheduled_pushes (
  id BIGSERIAL PRIMARY KEY,
  send_at TIMESTAMPTZ NOT NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  category TEXT,
  sent BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_scheduled_pushes_due ON scheduled_pushes (sent, send_at);

-- Intervention state the phone polls (e.g. shield strictness).
CREATE TABLE IF NOT EXISTS device_directives (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Key/value state (sync cursors, etc).
CREATE TABLE IF NOT EXISTS kv_state (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
`;

export async function migrate(): Promise<void> {
  await pool.query(SCHEMA);
}

export async function upsertMetric(
  day: string,
  source: string,
  metric: string,
  value: number | null,
  meta?: unknown,
): Promise<void> {
  await query(
    `INSERT INTO metrics (day, source, metric, value, meta, updated_at)
     VALUES ($1, $2, $3, $4, $5, now())
     ON CONFLICT (day, source, metric)
     DO UPDATE SET value = EXCLUDED.value, meta = EXCLUDED.meta, updated_at = now()`,
    [day, source, metric, value, meta === undefined ? null : JSON.stringify(meta)],
  );
}

export async function getKV<T>(key: string): Promise<T | null> {
  const r = await query<{ value: T }>(`SELECT value FROM kv_state WHERE key = $1`, [key]);
  return r.rows[0]?.value ?? null;
}

export async function setKV(key: string, value: unknown): Promise<void> {
  await query(
    `INSERT INTO kv_state (key, value, updated_at) VALUES ($1, $2, now())
     ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()`,
    [key, JSON.stringify(value)],
  );
}

export async function setDirective(key: string, value: unknown): Promise<void> {
  await query(
    `INSERT INTO device_directives (key, value, updated_at) VALUES ($1, $2, now())
     ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()`,
    [key, JSON.stringify(value)],
  );
}
