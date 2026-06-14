import { userClock } from "./config.js";
import { getKV, setKV, query } from "./db.js";
import { agentConfigured, eveningWinddown, morningBriefing, weeklyReport } from "./agent.js";
import { isConnected, renewSubscriptions, syncRecent } from "./oura.js";
import { syncWeather } from "./weather.js";
import { pushToAllDevices, wakeAllDevices } from "./apns.js";

/**
 * If the on-device Apple Foundation Models agent doesn't report a delivered
 * job within this many minutes of its due time, the server falls back to
 * generating with Claude and pushing it, so a notification always arrives.
 */
const FALLBACK_DELAY_MIN = 8;

type AgentEngine = "backendClaude" | "shadow" | "onDeviceApple";

interface JobSpec {
  kind: string;                       // briefing | winddown | weekly
  dueMin: number;                     // minutes since local midnight
  weekday: number | null;             // 0=Sun, or null for every day
  generate: () => Promise<string>;
  title: string;
  body: (text: string) => string;
  category: string;
}

/**
 * Minute tick. Jobs are idempotent per day via kv_state markers, so restarts
 * and Railway redeploys are safe.
 */

async function ranToday(job: string): Promise<boolean> {
  const { dateStr } = userClock();
  return (await getKV<string>(`job:${job}`)) === dateStr;
}

async function markRan(job: string): Promise<void> {
  const { dateStr } = userClock();
  await setKV(`job:${job}`, dateStr);
}

async function deliverDuePushes(): Promise<void> {
  const due = await query<{ id: number; title: string; body: string; category: string | null }>(
    `SELECT id, title, body, category FROM scheduled_pushes WHERE NOT sent AND send_at <= now() ORDER BY send_at LIMIT 10`,
  );
  for (const p of due.rows) {
    await pushToAllDevices(p.title, p.body, p.category ?? undefined);
    await query(`UPDATE scheduled_pushes SET sent = true WHERE id = $1`, [p.id]);
  }
}

async function tick(): Promise<void> {
  const clock = userClock();
  await deliverDuePushes();

  const connected = await isConnected();

  // Safety-net sync every 3 hours (webhooks are primary).
  if (connected && clock.minute < 1 && clock.hour % 3 === 0) {
    const marker = `sync:${clock.dateStr}:${clock.hour}`;
    if ((await getKV<string>("job:lastsync")) !== marker) {
      await setKV("job:lastsync", marker);
      await syncRecent().catch((e) => console.error("syncRecent failed", e));
    }
  }

  // Daily weather at 05:30.
  if (clock.hour === 5 && clock.minute >= 30 && !(await ranToday("weather"))) {
    await markRan("weather");
    await syncWeather(3).catch((e) => console.error("weather failed", e));
  }

  // Webhook renewal at 04:00.
  if (connected && clock.hour === 4 && !(await ranToday("renew"))) {
    await markRan("renew");
    await renewSubscriptions().catch((e) => console.error("renew failed", e));
  }

  if (!connected) return;

  const engine = ((await getKV<string>("agent_engine")) ?? "backendClaude") as AgentEngine;
  const nowMin = clock.hour * 60 + clock.minute;

  const jobs: JobSpec[] = [
    {
      kind: "briefing", dueMin: 7 * 60 + 15, weekday: null,
      generate: morningBriefing, title: "Morning briefing",
      body: (t) => firstSentences(t, 180), category: "BRIEFING",
    },
    {
      kind: "winddown", dueMin: 21 * 60, weekday: null,
      generate: eveningWinddown, title: "Wind-down",
      body: (t) => firstSentences(t, 180), category: "WINDDOWN",
    },
    {
      kind: "weekly", dueMin: 19 * 60, weekday: 0,
      generate: weeklyReport, title: "Weekly life report",
      body: () => "Your week, analyzed. Open Myra to read it.", category: "WEEKLY",
    },
  ];

  for (const job of jobs) {
    if (job.weekday !== null && clock.weekday !== job.weekday) continue;
    await runJob(job, engine, nowMin).catch((e) => console.error(`${job.kind} job failed`, e));
  }
}

/** Generate with Claude and deliver the alert push — the original behavior. */
async function claudeDeliver(job: JobSpec): Promise<void> {
  if (!agentConfigured()) return;
  try {
    const text = await job.generate();
    await pushToAllDevices(job.title, job.body(text), job.category, { kind: job.kind });
  } catch (e) {
    console.error(`${job.kind} (claude) failed`, e);
  }
}

/**
 * Drives a scheduled job according to the selected engine:
 * - backendClaude: generate + push with Claude (unchanged behavior).
 * - shadow: Claude stays primary (+push); also wake the device to produce a
 *   shadow Apple output (uploaded, not pushed) for comparison.
 * - onDeviceApple: wake the device (primary); if it doesn't report delivery
 *   within FALLBACK_DELAY_MIN, Claude steps in so a push always arrives.
 */
async function runJob(job: JobSpec, engine: AgentEngine, nowMin: number): Promise<void> {
  // Primary action at the due time, once per day.
  if (nowMin >= job.dueMin && !(await ranToday(job.kind))) {
    await markRan(job.kind);
    if (engine === "backendClaude") {
      await claudeDeliver(job);
    } else if (engine === "shadow") {
      await claudeDeliver(job);
      await wakeAllDevices(job.kind).catch((e) => console.error("wake failed", e));
    } else if (engine === "onDeviceApple") {
      await wakeAllDevices(job.kind).catch((e) => console.error("wake failed", e));
    }
  }

  // Fallback for onDeviceApple: if the device didn't deliver in time, use Claude.
  if (engine === "onDeviceApple" &&
      nowMin >= job.dueMin + FALLBACK_DELAY_MIN &&
      !(await ranToday(`${job.kind}:fallback`))) {
    const delivered = (await getKV<string>(`job:${job.kind}:delivered`)) === userClock().dateStr;
    if (!delivered) {
      await markRan(`${job.kind}:fallback`);
      await claudeDeliver(job);
    }
  }
}

function firstSentences(text: string, maxLen: number): string {
  if (text.length <= maxLen) return text;
  return text.slice(0, maxLen - 1).replace(/\s+\S*$/, "") + "…";
}

export function startScheduler(): void {
  setInterval(() => {
    tick().catch((e) => console.error("scheduler tick failed", e));
  }, 60_000);
  console.log("scheduler started");
}
