import { Hono } from "hono";
import { serve } from "@hono/node-server";
import crypto from "node:crypto";
import { config, daysAgoStr, userClock } from "./config.js";
import { migrate, query, upsertMetric, getKV, setKV } from "./db.js";
import {
  authorizeUrl, exchangeCode, isConnected, backfillHistory, syncRecent,
  ensureSubscriptions, listSubscriptions, fetchDocument, storeDocument,
  type OuraDataType,
} from "./oura.js";
import { syncWeather } from "./weather.js";
import { discoverCorrelations, loadDailyMatrix, optimalBedtimeWindow, sleepDebt } from "./stats.js";
import {
  agentConfigured, chat, morningBriefing, eveningWinddown, weeklyReport,
  agentContext, runTool, saveAgentMessage,
} from "./agent.js";
import { startScheduler } from "./scheduler.js";

const app = new Hono();

app.get("/health", (c) => c.json({ ok: true, time: new Date().toISOString() }));

// ---------------- Oura OAuth ----------------

app.get("/oauth/start", (c) => {
  const state = crypto.randomBytes(16).toString("hex");
  return c.redirect(authorizeUrl(state));
});

app.get("/oauth/callback", async (c) => {
  const code = c.req.query("code");
  const error = c.req.query("error");
  if (error) return c.html(`<h2>Oura authorization failed: ${error}</h2>`);
  if (!code) return c.html(`<h2>Missing code</h2>`, 400);
  await exchangeCode(code);

  // Kick off historical backfill + webhook subscriptions in the background.
  (async () => {
    try {
      console.log("backfill starting…");
      const counts = await backfillHistory(365);
      console.log("backfill done:", counts);
      const subs = await ensureSubscriptions();
      console.log("subscriptions:", subs);
      await syncWeather(90).catch(() => {});
      await setKV("backfill_done", new Date().toISOString());
    } catch (e) {
      console.error("post-connect setup failed:", e);
    }
  })();

  return c.html(
    `<div style="font-family:-apple-system,sans-serif;text-align:center;padding-top:30vh">
      <h1>Oura connected</h1>
      <p>Myra is importing your last year of data. You can close this and return to the app.</p>
      <a href="myra://connected">Open Myra</a>
    </div>`,
  );
});

// ---------------- Oura webhooks ----------------

// Subscription verification handshake.
app.get("/webhooks/oura", (c) => {
  const token = c.req.query("verification_token");
  const challenge = c.req.query("challenge");
  if (token === config.oura.webhookVerificationToken) {
    return c.json({ challenge });
  }
  return c.text("invalid verification token", 401);
});

app.post("/webhooks/oura", async (c) => {
  const raw = await c.req.text();

  // Verify HMAC signature when present.
  const sig = c.req.header("x-oura-signature");
  if (sig && config.oura.clientSecret) {
    const expected = "sha256=" + crypto.createHmac("sha256", config.oura.clientSecret).update(raw).digest("hex");
    const a = Buffer.from(sig);
    const b = Buffer.from(expected);
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
      return c.text("bad signature", 401);
    }
  }

  let event: any;
  try {
    event = JSON.parse(raw);
  } catch {
    return c.text("bad json", 400);
  }

  // Ack immediately; fetch the document asynchronously.
  (async () => {
    try {
      const { data_type, object_id, event_type } = event;
      if (event_type === "delete" || !data_type || !object_id) return;
      const doc = await fetchDocument(data_type as OuraDataType, object_id);
      await storeDocument(data_type as OuraDataType, doc);
      console.log(`webhook: stored ${data_type}/${object_id}`);
    } catch (e) {
      console.error("webhook processing failed:", e);
    }
  })();

  return c.json({ ok: true });
});

// ---------------- App API (authenticated) ----------------

const api = new Hono();

api.use("*", async (c, next) => {
  if (config.appToken && c.req.header("x-app-token") !== config.appToken) {
    return c.text("unauthorized", 401);
  }
  await next();
});

api.get("/status", async (c) => {
  const connected = await isConnected();
  const backfill = await getKV<string>("backfill_done");
  const lastMetric = await query<{ max: string }>(`SELECT to_char(max(day),'YYYY-MM-DD') AS max FROM metrics WHERE source='oura'`);
  return c.json({
    ouraConnected: connected,
    backfillDone: Boolean(backfill),
    latestOuraDay: lastMetric.rows[0]?.max ?? null,
    agentConfigured: agentConfigured(),
    oauthStartUrl: `${config.baseUrl}/oauth/start`,
  });
});

// Today + recent trends in one call for the dashboard.
api.get("/dashboard", async (c) => {
  const days = Number(c.req.query("days") ?? 30);
  const matrix = await loadDailyMatrix(Math.min(days, 365));
  const debt = await sleepDebt();
  const window = await optimalBedtimeWindow();
  const latestBriefing = await query<{ content: string; created_at: string }>(
    `SELECT content, created_at FROM agent_messages WHERE kind IN ('briefing','winddown','weekly')
     ORDER BY created_at DESC LIMIT 1`,
  );
  const directives = await query<{ key: string; value: unknown }>(`SELECT key, value FROM device_directives`);
  return c.json({
    days: matrix,
    sleepDebt: debt,
    optimalBedtime: window,
    latestMessage: latestBriefing.rows[0] ?? null,
    directives: Object.fromEntries(directives.rows.map((d) => [d.key, d.value])),
  });
});

api.get("/insights", async (c) => {
  const correlations = await discoverCorrelations();
  return c.json({ correlations, sleepDebt: await sleepDebt(), optimalBedtime: await optimalBedtimeWindow() });
});

api.get("/messages", async (c) => {
  const kind = c.req.query("kind");
  const r = await query(
    kind
      ? `SELECT id, kind, content, created_at FROM agent_messages WHERE kind = $1 ORDER BY created_at DESC LIMIT 50`
      : `SELECT id, kind, content, created_at FROM agent_messages WHERE kind NOT IN ('chat_user','chat_assistant') ORDER BY created_at DESC LIMIT 50`,
    kind ? [kind] : [],
  );
  return c.json(r.rows);
});

api.get("/chat/history", async (c) => {
  const r = await query(
    `SELECT id, kind, content, created_at FROM agent_messages
     WHERE kind IN ('chat_user','chat_assistant') ORDER BY created_at DESC LIMIT 50`,
  );
  return c.json(r.rows.reverse());
});

api.post("/chat", async (c) => {
  const { message } = await c.req.json<{ message: string }>();
  if (!message?.trim()) return c.text("empty", 400);
  if (!agentConfigured()) return c.json({ reply: "Claude API key not configured on the backend yet." });
  const reply = await chat(message.trim());
  return c.json({ reply });
});

// ---- On-device Apple Foundation Models bridge ----
// The on-device agent runs the LLM + tool loop on the phone, but every tool
// call and every statistic is still produced by the same server code below, so
// no data path changes and nothing is lost.

// Context for assembling the on-device system prompt (mirrors systemPrompt()).
api.get("/agent/context", async (c) => c.json(await agentContext()));

// Single dispatch endpoint that reuses all 9 tool implementations verbatim.
api.post("/agent/tool", async (c) => {
  const { name, input } = await c.req.json<{ name: string; input?: unknown }>();
  if (!name) return c.text("missing tool name", 400);
  try {
    const result = await runTool(name, input ?? {});
    return c.json({ result });
  } catch (e) {
    return c.json({ error: String(e) }, 500);
  }
});

// Device uploads a generated message (briefing/winddown/weekly/chat). meta.model
// distinguishes apple-ondevice | apple-pcc | claude for the dashboard + shadow eval.
api.post("/agent/messages", async (c) => {
  const { kind, content, meta } = await c.req.json<{ kind: string; content: string; meta?: unknown }>();
  if (!kind || !content?.trim()) return c.text("missing kind/content", 400);
  await saveAgentMessage(kind, content.trim(), meta);
  return c.json({ ok: true });
});

// Device marks a scheduled job as delivered so the server fallback stands down.
api.post("/agent/jobs/:kind/complete", async (c) => {
  const kind = c.req.param("kind");
  await setKV(`job:${kind}:delivered`, userClock().dateStr);
  return c.json({ ok: true });
});

// The app reports which engine it's running so the scheduler knows whether to
// generate with Claude, run in shadow, or defer to the on-device Apple agent.
// Defaults to backendClaude server-side, preserving current behavior.
api.get("/agent/engine", async (c) => {
  const engine = (await getKV<string>("agent_engine")) ?? "backendClaude";
  return c.json({ engine });
});

api.post("/agent/engine", async (c) => {
  const { engine } = await c.req.json<{ engine: string }>();
  const allowed = ["backendClaude", "shadow", "onDeviceApple"];
  if (!allowed.includes(engine)) return c.text("invalid engine", 400);
  await setKV("agent_engine", engine);
  return c.json({ ok: true, engine });
});

// ---- Ingestion from the phone ----

interface DailyMetricUpload {
  day: string;        // YYYY-MM-DD
  source: string;     // healthkit | screentime | calendar
  metric: string;
  value: number;
  meta?: unknown;
}

api.post("/ingest/daily", async (c) => {
  const body = await c.req.json<{ metrics: DailyMetricUpload[] }>();
  let n = 0;
  for (const m of body.metrics ?? []) {
    if (!m.day || !m.metric || typeof m.value !== "number") continue;
    await upsertMetric(m.day, m.source ?? "healthkit", m.metric, m.value, m.meta);
    n++;
  }
  return c.json({ stored: n });
});

api.post("/ingest/samples", async (c) => {
  const body = await c.req.json<{ samples: Array<{ ts: string; metric: string; value: number; source?: string }> }>();
  let n = 0;
  for (const s of body.samples ?? []) {
    if (!s.ts || !s.metric || typeof s.value !== "number") continue;
    await query(
      `INSERT INTO samples (ts, source, metric, value) VALUES ($1,$2,$3,$4)
       ON CONFLICT (ts, source, metric) DO UPDATE SET value = EXCLUDED.value`,
      [s.ts, s.source ?? "healthkit", s.metric, s.value],
    );
    n++;
  }
  return c.json({ stored: n });
});

api.post("/ingest/calendar", async (c) => {
  const body = await c.req.json<{
    events: Array<{ id: string; title: string; start: string; end: string; allDay?: boolean }>;
  }>();
  let n = 0;
  for (const e of body.events ?? []) {
    if (!e.id || !e.start || !e.end) continue;
    await query(
      `INSERT INTO calendar_events (event_id, title, starts_at, ends_at, is_all_day, updated_at)
       VALUES ($1,$2,$3,$4,$5,now())
       ON CONFLICT (event_id) DO UPDATE SET title=$2, starts_at=$3, ends_at=$4, is_all_day=$5, updated_at=now()`,
      [e.id, e.title ?? "", e.start, e.end, e.allDay ?? false],
    );
    n++;
  }

  // Derive daily calendar-load metrics for the stats engine.
  const r = await query<{ day: string; cnt: string; busy: string; first_min: string }>(
    `SELECT to_char(starts_at AT TIME ZONE $1, 'YYYY-MM-DD') AS day,
            count(*) AS cnt,
            sum(EXTRACT(EPOCH FROM (ends_at - starts_at))) AS busy,
            min(EXTRACT(HOUR FROM starts_at AT TIME ZONE $1) * 60 + EXTRACT(MINUTE FROM starts_at AT TIME ZONE $1)) AS first_min
     FROM calendar_events
     WHERE NOT is_all_day AND starts_at >= now() - interval '30 days'
     GROUP BY 1`,
    [config.userTimezone],
  );
  for (const row of r.rows) {
    await upsertMetric(row.day, "calendar", "meeting_count", Number(row.cnt));
    await upsertMetric(row.day, "calendar", "calendar_busy_s", Number(row.busy));
    await upsertMetric(row.day, "calendar", "first_event_min", Number(row.first_min));
  }
  return c.json({ stored: n });
});

api.post("/devices", async (c) => {
  const { token } = await c.req.json<{ token: string }>();
  if (!token) return c.text("missing token", 400);
  await query(
    `INSERT INTO devices (token, updated_at) VALUES ($1, now())
     ON CONFLICT (token) DO UPDATE SET updated_at = now()`,
    [token],
  );
  return c.json({ ok: true });
});

api.get("/directives", async (c) => {
  const r = await query<{ key: string; value: unknown }>(`SELECT key, value FROM device_directives`);
  return c.json(Object.fromEntries(r.rows.map((d) => [d.key, d.value])));
});

// ---- Experiments ----

api.get("/experiments", async (c) => {
  const r = await query(`SELECT * FROM experiments ORDER BY created_at DESC LIMIT 20`);
  return c.json(r.rows);
});

api.post("/experiments/:id/log", async (c) => {
  const id = Number(c.req.param("id"));
  const { day, complied, note } = await c.req.json<{ day?: string; complied: boolean; note?: string }>();
  const d = day ?? userClock().dateStr;
  await query(
    `INSERT INTO experiment_logs (experiment_id, day, complied, note) VALUES ($1,$2,$3,$4)
     ON CONFLICT (experiment_id, day) DO UPDATE SET complied = $3, note = $4`,
    [id, d, complied, note ?? null],
  );
  return c.json({ ok: true });
});

// ---- Manual triggers (for setup & testing) ----

api.post("/admin/backfill", async (c) => {
  const days = Number(c.req.query("days") ?? 365);
  const counts = await backfillHistory(days);
  await setKV("backfill_done", new Date().toISOString());
  return c.json(counts);
});

api.post("/admin/sync", async (c) => c.json(await syncRecent()));
api.post("/admin/subscribe", async (c) => c.json(await ensureSubscriptions()));
api.get("/admin/subscriptions", async (c) => c.json(await listSubscriptions()));
api.post("/admin/weather", async (c) => c.json({ days: await syncWeather(Number(c.req.query("days") ?? 90)) }));
api.post("/admin/briefing", async (c) => c.json({ text: await morningBriefing() }));
api.post("/admin/winddown", async (c) => c.json({ text: await eveningWinddown() }));
api.post("/admin/weekly", async (c) => c.json({ text: await weeklyReport() }));

app.route("/api", api);

// ---------------- Boot ----------------

async function main() {
  if (!config.databaseUrl) {
    console.error("DATABASE_URL is required");
    process.exit(1);
  }
  await migrate();
  startScheduler();
  serve({ fetch: app.fetch, port: config.port }, (info) => {
    console.log(`myra backend listening on :${info.port}`);
  });
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
