import { config, daysAgoStr } from "./config.js";
import { query, upsertMetric } from "./db.js";

const AUTH_URL = "https://cloud.ouraring.com/oauth/authorize";
const TOKEN_URL = "https://api.ouraring.com/oauth/token";
const API = "https://api.ouraring.com/v2";

export const OURA_DATA_TYPES = [
  "daily_sleep",
  "daily_readiness",
  "daily_activity",
  "daily_stress",
  "daily_spo2",
  "sleep",
  "workout",
  "session",
  "enhanced_tag",
] as const;
export type OuraDataType = (typeof OURA_DATA_TYPES)[number];

// ---------- OAuth ----------

export function authorizeUrl(state: string): string {
  const u = new URL(AUTH_URL);
  u.searchParams.set("response_type", "code");
  u.searchParams.set("client_id", config.oura.clientId);
  u.searchParams.set("redirect_uri", `${config.baseUrl}/oauth/callback`);
  u.searchParams.set("scope", config.oura.scopes);
  u.searchParams.set("state", state);
  return u.toString();
}

interface TokenResponse {
  access_token: string;
  refresh_token: string;
  expires_in: number;
}

async function tokenRequest(params: Record<string, string>): Promise<TokenResponse> {
  // Oura wants client credentials in the form body, not Basic auth.
  const body = new URLSearchParams({
    ...params,
    client_id: config.oura.clientId,
    client_secret: config.oura.clientSecret,
  });
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!res.ok) {
    throw new Error(`Oura token request failed: ${res.status} ${await res.text()}`);
  }
  return (await res.json()) as TokenResponse;
}

async function saveTokens(t: TokenResponse): Promise<void> {
  const expiresAt = new Date(Date.now() + (t.expires_in - 60) * 1000);
  await query(
    `INSERT INTO oura_tokens (id, access_token, refresh_token, expires_at, updated_at)
     VALUES (1, $1, $2, $3, now())
     ON CONFLICT (id) DO UPDATE SET access_token = $1, refresh_token = $2, expires_at = $3, updated_at = now()`,
    [t.access_token, t.refresh_token, expiresAt.toISOString()],
  );
}

export async function exchangeCode(code: string): Promise<void> {
  const t = await tokenRequest({
    grant_type: "authorization_code",
    code,
    redirect_uri: `${config.baseUrl}/oauth/callback`,
  });
  await saveTokens(t);
}

export async function isConnected(): Promise<boolean> {
  const r = await query(`SELECT 1 FROM oura_tokens WHERE id = 1`);
  return r.rowCount === 1;
}

let refreshing: Promise<string> | null = null;

// Refresh tokens are single-use; serialize refreshes so concurrent callers
// don't each consume (and invalidate) the rotating refresh token.
function refreshAccessToken(refreshToken: string): Promise<string> {
  if (!refreshing) {
    refreshing = (async () => {
      try {
        const t = await tokenRequest({ grant_type: "refresh_token", refresh_token: refreshToken });
        await saveTokens(t);
        return t.access_token;
      } finally {
        refreshing = null;
      }
    })();
  }
  return refreshing;
}

export async function accessToken(forceRefresh = false): Promise<string> {
  const r = await query<{ access_token: string; refresh_token: string; expires_at: string }>(
    `SELECT access_token, refresh_token, expires_at FROM oura_tokens WHERE id = 1`,
  );
  const row = r.rows[0];
  if (!row) throw new Error("Oura not connected — open /oauth/start");
  if (!forceRefresh && new Date(row.expires_at).getTime() > Date.now()) return row.access_token;
  return refreshAccessToken(row.refresh_token);
}

// ---------- API ----------

async function ouraGet<T>(path: string, params?: Record<string, string>): Promise<T> {
  const u = new URL(`${API}${path}`);
  for (const [k, v] of Object.entries(params ?? {})) u.searchParams.set(k, v);
  const send = (token: string) => fetch(u, { headers: { Authorization: `Bearer ${token}` } });

  let res = await send(await accessToken());
  // A revoked (but not yet clock-expired) token still returns 401. Force a
  // single refresh + retry so a stale token self-heals instead of silently
  // failing every sync until someone re-runs OAuth by hand.
  if (res.status === 401) {
    res = await send(await accessToken(true));
  }
  if (!res.ok) throw new Error(`Oura GET ${path} failed: ${res.status} ${await res.text()}`);
  return (await res.json()) as T;
}

interface Paged<T> {
  data: T[];
  next_token: string | null;
}

export async function fetchCollection(dataType: OuraDataType, startDate: string, endDate: string): Promise<any[]> {
  const out: any[] = [];
  let nextToken: string | null = null;
  do {
    const params: Record<string, string> = { start_date: startDate, end_date: endDate };
    if (nextToken) params.next_token = nextToken;
    const page: Paged<any> = await ouraGet(`/usercollection/${dataType}`, params);
    out.push(...page.data);
    nextToken = page.next_token;
  } while (nextToken);
  return out;
}

export async function fetchDocument(dataType: OuraDataType, docId: string): Promise<any> {
  return ouraGet(`/usercollection/${dataType}/${docId}`);
}

export interface HeartrateSample {
  bpm: number;
  source: string;
  timestamp: string;
}

/**
 * Intraday heart-rate samples between two ISO-8601 datetimes (offset form, e.g.
 * `2026-06-19T00:00:00+02:00`). Follows next_token pagination and returns the
 * full day in one array. Unlike the daily collections this endpoint uses
 * start_datetime/end_datetime, not start_date/end_date.
 */
export async function fetchHeartrate(startDatetime: string, endDatetime: string): Promise<HeartrateSample[]> {
  const out: HeartrateSample[] = [];
  let nextToken: string | null = null;
  do {
    const params: Record<string, string> = { start_datetime: startDatetime, end_datetime: endDatetime };
    if (nextToken) params.next_token = nextToken;
    const page: Paged<HeartrateSample> = await ouraGet(`/usercollection/heartrate`, params);
    out.push(...page.data);
    nextToken = page.next_token;
  } while (nextToken);
  out.sort((a, b) => a.timestamp.localeCompare(b.timestamp));
  return out;
}

export async function fetchPersonalInfo(): Promise<any> {
  return ouraGet(`/usercollection/personal_info`);
}

// ---------- Normalization into the unified timeline ----------

function docDay(dataType: OuraDataType, doc: any): string | null {
  return doc.day ?? doc.start_datetime?.slice(0, 10) ?? doc.start_date ?? null;
}

export async function storeDocument(dataType: OuraDataType, doc: any): Promise<void> {
  const day = docDay(dataType, doc);
  await query(
    `INSERT INTO oura_documents (data_type, doc_id, day, payload, updated_at)
     VALUES ($1, $2, $3, $4, now())
     ON CONFLICT (data_type, doc_id) DO UPDATE SET day = EXCLUDED.day, payload = EXCLUDED.payload, updated_at = now()`,
    [dataType, doc.id ?? `${dataType}-${day}`, day, JSON.stringify(doc)],
  );
  await normalizeDocument(dataType, doc);
}

async function normalizeDocument(dataType: OuraDataType, doc: any): Promise<void> {
  const day = docDay(dataType, doc);
  if (!day) return;
  const m = (metric: string, value: number | null | undefined, meta?: unknown) => {
    if (value === null || value === undefined || Number.isNaN(value)) return Promise.resolve();
    return upsertMetric(day, "oura", metric, value, meta);
  };

  switch (dataType) {
    case "daily_sleep":
      await m("sleep_score", doc.score, doc.contributors);
      break;
    case "daily_readiness":
      await m("readiness_score", doc.score, doc.contributors);
      await m("temperature_deviation", doc.temperature_deviation);
      break;
    case "daily_activity":
      await m("activity_score", doc.score);
      await m("steps", doc.steps);
      await m("active_calories", doc.active_calories);
      await m("total_calories", doc.total_calories);
      await m("sedentary_time_s", doc.sedentary_time);
      break;
    case "daily_stress":
      await m("stress_high_s", doc.stress_high);
      await m("recovery_high_s", doc.recovery_high);
      break;
    case "daily_spo2":
      await m("spo2_avg", doc.spo2_percentage?.average);
      await m("breathing_disturbance_index", doc.breathing_disturbance_index);
      break;
    case "sleep": {
      // Only the main long sleep period drives daily metrics.
      if (doc.type && doc.type !== "long_sleep") break;
      await m("total_sleep_s", doc.total_sleep_duration);
      await m("deep_sleep_s", doc.deep_sleep_duration);
      await m("rem_sleep_s", doc.rem_sleep_duration);
      await m("light_sleep_s", doc.light_sleep_duration);
      await m("awake_s", doc.awake_time);
      await m("sleep_efficiency", doc.efficiency);
      await m("sleep_latency_s", doc.latency);
      await m("avg_hrv", doc.average_hrv);
      await m("avg_hr_sleep", doc.average_heart_rate);
      await m("lowest_hr_sleep", doc.lowest_heart_rate);
      await m("avg_breath", doc.average_breath);
      if (doc.bedtime_start) {
        // Minutes past midnight (can exceed 1440 if after midnight relative to previous evening).
        const bt = new Date(doc.bedtime_start);
        const fmt = new Intl.DateTimeFormat("en-GB", {
          timeZone: config.userTimezone, hour: "2-digit", minute: "2-digit", hour12: false,
        }).format(bt);
        const [h, min] = fmt.split(":").map(Number);
        const minutes = h * 60 + min;
        // Normalize so evening times sort before after-midnight times: 18:00 -> 1080, 01:00 -> 1500.
        await m("bedtime_start_min", minutes < 720 ? minutes + 1440 : minutes, { iso: doc.bedtime_start });
      }
      break;
    }
    case "workout":
      await m(`workout_${doc.activity ?? "unknown"}_s`, durationSeconds(doc), { intensity: doc.intensity });
      break;
    case "session":
      await m(`session_${doc.type ?? "unknown"}_s`, durationSeconds(doc), { mood: doc.mood });
      break;
    case "enhanced_tag":
      await upsertMetric(day, "oura", `tag_${doc.tag_type_code ?? "custom"}`, 1, {
        comment: doc.comment,
        start: doc.start_time,
      });
      break;
  }
}

function durationSeconds(doc: any): number | null {
  if (!doc.start_datetime || !doc.end_datetime) return null;
  return (new Date(doc.end_datetime).getTime() - new Date(doc.start_datetime).getTime()) / 1000;
}

// ---------- Sync / backfill ----------

export async function syncRange(startDate: string, endDate: string): Promise<Record<string, number>> {
  const counts: Record<string, number> = {};
  for (const dt of OURA_DATA_TYPES) {
    try {
      const docs = await fetchCollection(dt, startDate, endDate);
      for (const doc of docs) await storeDocument(dt, doc);
      counts[dt] = docs.length;
    } catch (e) {
      console.error(`sync ${dt} failed:`, e);
      counts[dt] = -1;
    }
  }
  return counts;
}

export async function backfillHistory(days = 365): Promise<Record<string, number>> {
  return syncRange(daysAgoStr(days), daysAgoStr(-1));
}

export async function syncRecent(): Promise<Record<string, number>> {
  return syncRange(daysAgoStr(7), daysAgoStr(-1));
}

// ---------- Webhook subscriptions ----------

const WEBHOOK_API = "https://api.ouraring.com/v2/webhook/subscription";

function webhookHeaders(): Record<string, string> {
  return {
    "x-client-id": config.oura.clientId,
    "x-client-secret": config.oura.clientSecret,
    "Content-Type": "application/json",
  };
}

export async function listSubscriptions(): Promise<any[]> {
  const res = await fetch(WEBHOOK_API, { headers: webhookHeaders() });
  if (!res.ok) throw new Error(`list subscriptions failed: ${res.status} ${await res.text()}`);
  return (await res.json()) as any[];
}

export async function ensureSubscriptions(): Promise<{ created: string[]; existing: number; errors: string[] }> {
  const existing = await listSubscriptions();
  const have = new Set(existing.map((s) => `${s.event_type}:${s.data_type}`));
  const created: string[] = [];
  const errors: string[] = [];
  const callbackUrl = `${config.baseUrl}/webhooks/oura`;

  for (const dataType of OURA_DATA_TYPES) {
    for (const eventType of ["create", "update"]) {
      const key = `${eventType}:${dataType}`;
      if (have.has(key)) continue;
      const res = await fetch(WEBHOOK_API, {
        method: "POST",
        headers: webhookHeaders(),
        body: JSON.stringify({
          callback_url: callbackUrl,
          verification_token: config.oura.webhookVerificationToken,
          event_type: eventType,
          data_type: dataType,
        }),
      });
      if (res.ok) created.push(key);
      else errors.push(`${key}: ${res.status} ${await res.text()}`);
    }
  }
  return { created, existing: existing.length, errors };
}

export async function renewSubscriptions(): Promise<void> {
  const subs = await listSubscriptions();
  for (const s of subs) {
    const expires = new Date(s.expiration_time).getTime();
    if (expires - Date.now() < 3 * 86400_000) {
      await fetch(`${WEBHOOK_API}/renew/${s.id}`, { method: "PUT", headers: webhookHeaders() });
    }
  }
}
