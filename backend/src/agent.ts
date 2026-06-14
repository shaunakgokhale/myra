import Anthropic from "@anthropic-ai/sdk";
import { config, daysAgoStr, userClock } from "./config.js";
import { query, setDirective } from "./db.js";
import { discoverCorrelations, evaluateEffect, loadDailyMatrix, optimalBedtimeWindow, sleepDebt } from "./stats.js";

const client = () => new Anthropic({ apiKey: config.anthropic.apiKey });

export function agentConfigured(): boolean {
  return Boolean(config.anthropic.apiKey);
}

// ---------- Tools ----------

const TOOLS: Anthropic.Tool[] = [
  {
    name: "query_metrics",
    description:
      "Query the unified daily timeline. Returns rows of {day, metric, value} for the requested metrics over the last N days. Metric names include: sleep_score, readiness_score, activity_score, total_sleep_s, deep_sleep_s, rem_sleep_s, avg_hrv, lowest_hr_sleep, sleep_efficiency, sleep_latency_s, bedtime_start_min (minutes, 1380=23:00, 1500=01:00), steps, active_calories, sedentary_time_s, stress_high_s, temperature_deviation, spo2_avg, screen_total_min, screen_late_min, meeting_count, calendar_busy_s, first_event_min, mindful_min, caffeine_mg, alcohol_drinks, temp_max_c, daylight_s, plus workout_*/session_*/tag_* entries.",
    input_schema: {
      type: "object" as const,
      properties: {
        metrics: { type: "array", items: { type: "string" }, description: "Metric names to fetch" },
        days: { type: "number", description: "How many days back (default 30)" },
      },
      required: ["metrics"],
    },
  },
  {
    name: "run_correlations",
    description:
      "Run the statistical discovery engine: lagged Pearson correlations between behaviors/context and body outcomes over the last 120 days. Returns only statistically meaningful results (|r|>=0.3, p<0.05, n>=10). lag=0 means same day, lag=1 means the input affects the NEXT day's outcome.",
    input_schema: { type: "object" as const, properties: {}, required: [] },
  },
  {
    name: "get_sleep_analysis",
    description: "Get computed sleep debt (vs personal need) and the statistically optimal bedtime window.",
    input_schema: { type: "object" as const, properties: {}, required: [] },
  },
  {
    name: "get_calendar",
    description: "Get calendar events between now and N days ahead (default 2), including meeting load.",
    input_schema: {
      type: "object" as const,
      properties: { days_ahead: { type: "number" } },
      required: [],
    },
  },
  {
    name: "remember",
    description:
      "Write a fact to long-term memory so future briefings/conversations know it. Use for discovered patterns, user preferences, what advice was followed or ignored, and outcomes of suggestions. Keep each memory one sentence.",
    input_schema: {
      type: "object" as const,
      properties: {
        category: { type: "string", enum: ["pattern", "preference", "outcome", "observation"] },
        content: { type: "string" },
        importance: { type: "number", description: "1-10" },
      },
      required: ["category", "content"],
    },
  },
  {
    name: "schedule_push",
    description:
      "Schedule a push notification to the user's phone at a specific time (ISO 8601 with timezone). Use sparingly and only when timing matters (bedtime nudge, pre-meeting recovery reminder).",
    input_schema: {
      type: "object" as const,
      properties: {
        send_at: { type: "string", description: "ISO timestamp" },
        title: { type: "string" },
        body: { type: "string" },
      },
      required: ["send_at", "title", "body"],
    },
  },
  {
    name: "set_shield_policy",
    description:
      "Set tonight's Screen Time shield policy on the phone. strictness: 0=off, 1=gentle (shield from winddown time), 2=strict (shield earlier, stronger copy). Set winddown_time as HH:MM in the user's timezone. Scale strictness with sleep debt: debt > 5h => 2, debt 2-5h => 1, else 0-1.",
    input_schema: {
      type: "object" as const,
      properties: {
        strictness: { type: "number" },
        winddown_time: { type: "string" },
        reason: { type: "string" },
      },
      required: ["strictness", "winddown_time", "reason"],
    },
  },
  {
    name: "propose_calendar_block",
    description:
      "Propose a recovery or wind-down block to be written into the user's calendar (the phone writes it via EventKit on next sync). Use for recovery blocks on heavy days or wind-down blocks before the optimal bedtime.",
    input_schema: {
      type: "object" as const,
      properties: {
        title: { type: "string", description: "e.g. 'Recovery block' or 'Wind-down'" },
        start: { type: "string", description: "ISO timestamp" },
        duration_minutes: { type: "number" },
        notes: { type: "string" },
      },
      required: ["title", "start", "duration_minutes"],
    },
  },
  {
    name: "propose_experiment",
    description:
      "Propose an n=1 experiment. Choose a clear intervention the user can comply with, a single target metric from the timeline, and a duration of 10-21 days. The baseline is the preceding period of equal length.",
    input_schema: {
      type: "object" as const,
      properties: {
        hypothesis: { type: "string" },
        intervention: { type: "string" },
        target_metric: { type: "string" },
        duration_days: { type: "number" },
      },
      required: ["hypothesis", "intervention", "target_metric", "duration_days"],
    },
  },
  {
    name: "evaluate_experiment",
    description: "Evaluate a completed or running experiment by id: compares the target metric against baseline (Cohen's d).",
    input_schema: {
      type: "object" as const,
      properties: { experiment_id: { type: "number" } },
      required: ["experiment_id"],
    },
  },
];

export async function runTool(name: string, input: any): Promise<unknown> {
  switch (name) {
    case "query_metrics": {
      const days = Math.min(365, input.days ?? 30);
      const r = await query(
        `SELECT to_char(day,'YYYY-MM-DD') AS day, metric, value FROM metrics
         WHERE metric = ANY($1) AND day >= $2 ORDER BY day, metric`,
        [input.metrics, daysAgoStr(days)],
      );
      return r.rows;
    }
    case "run_correlations":
      return discoverCorrelations();
    case "get_sleep_analysis":
      return { sleep_debt: await sleepDebt(), optimal_bedtime: await optimalBedtimeWindow() };
    case "get_calendar": {
      const daysAhead = input.days_ahead ?? 2;
      const r = await query(
        `SELECT title, starts_at, ends_at, is_all_day FROM calendar_events
         WHERE starts_at >= now() - interval '12 hours' AND starts_at < now() + ($1 || ' days')::interval
         ORDER BY starts_at`,
        [daysAhead],
      );
      return r.rows;
    }
    case "remember":
      await query(
        `INSERT INTO agent_memory (category, content, importance) VALUES ($1, $2, $3)`,
        [input.category, input.content, Math.min(10, Math.max(1, input.importance ?? 5))],
      );
      return { ok: true };
    case "schedule_push":
      await query(
        `INSERT INTO scheduled_pushes (send_at, title, body) VALUES ($1, $2, $3)`,
        [input.send_at, input.title, input.body],
      );
      return { ok: true };
    case "set_shield_policy":
      await setDirective("shield_policy", {
        strictness: input.strictness,
        winddownTime: input.winddown_time,
        reason: input.reason,
        setAt: new Date().toISOString(),
      });
      return { ok: true };
    case "propose_calendar_block":
      await setDirective("calendar_block", {
        title: input.title,
        start: input.start,
        durationMinutes: input.duration_minutes,
        notes: input.notes ?? null,
        proposedAt: new Date().toISOString(),
      });
      return { ok: true };
    case "propose_experiment": {
      const dur = Math.min(28, Math.max(7, input.duration_days ?? 14));
      const startDay = daysAgoStr(-1); // tomorrow
      const endDay = daysAgoStr(-dur);
      const baselineEnd = daysAgoStr(0);
      const baselineStart = daysAgoStr(dur - 1);
      const r = await query<{ id: number }>(
        `INSERT INTO experiments (hypothesis, intervention, target_metric, baseline_start, baseline_end, start_day, end_day, status)
         VALUES ($1,$2,$3,$4,$5,$6,$7,'active') RETURNING id`,
        [input.hypothesis, input.intervention, input.target_metric, baselineStart, baselineEnd, startDay, endDay],
      );
      return { ok: true, experiment_id: r.rows[0].id, start_day: startDay, end_day: endDay };
    }
    case "evaluate_experiment": {
      const r = await query<any>(`SELECT * FROM experiments WHERE id = $1`, [input.experiment_id]);
      const e = r.rows[0];
      if (!e) return { error: "not found" };
      const effect = await evaluateEffect(
        e.target_metric,
        e.baseline_start.toISOString?.()?.slice(0, 10) ?? String(e.baseline_start).slice(0, 10),
        e.baseline_end.toISOString?.()?.slice(0, 10) ?? String(e.baseline_end).slice(0, 10),
        e.start_day.toISOString?.()?.slice(0, 10) ?? String(e.start_day).slice(0, 10),
        e.end_day.toISOString?.()?.slice(0, 10) ?? String(e.end_day).slice(0, 10),
      );
      const compliance = await query<{ complied: boolean }>(
        `SELECT complied FROM experiment_logs WHERE experiment_id = $1`,
        [input.experiment_id],
      );
      const total = compliance.rowCount ?? 0;
      const yes = compliance.rows.filter((c) => c.complied).length;
      if (effect) {
        await query(`UPDATE experiments SET result = $2 WHERE id = $1`, [
          input.experiment_id,
          JSON.stringify({ ...effect, complianceRate: total ? yes / total : null }),
        ]);
      }
      return { effect, compliance: { logged: total, complied: yes } };
    }
    default:
      return { error: `unknown tool ${name}` };
  }
}

// ---------- System prompt assembly ----------

export async function memoryBlock(): Promise<string> {
  const r = await query<{ category: string; content: string }>(
    `SELECT category, content FROM agent_memory WHERE NOT archived ORDER BY importance DESC, created_at DESC LIMIT 40`,
  );
  if (!r.rowCount) return "(no long-term memories yet)";
  return r.rows.map((m) => `- [${m.category}] ${m.content}`).join("\n");
}

export async function activeExperimentsBlock(): Promise<string> {
  const r = await query<any>(
    `SELECT id, hypothesis, intervention, target_metric, start_day, end_day FROM experiments WHERE status = 'active'`,
  );
  if (!r.rowCount) return "(none)";
  return r.rows
    .map((e) => `- #${e.id}: ${e.hypothesis} | do: ${e.intervention} | metric: ${e.target_metric} | until ${String(e.end_day).slice(0, 10)}`)
    .join("\n");
}

export async function systemPrompt(): Promise<string> {
  const clock = userClock();
  return `You are Myra, an autonomous health agent for one person (Shaunak). You live in his iPhone and a backend that continuously ingests his Oura ring (sleep, HRV, readiness, stress), HealthKit (steps, workouts, heart rate, caffeine, alcohol, mindfulness), Screen Time, calendar, and weather.

Your loop: Observe -> Discover -> Intervene -> Verify -> Remember.

Principles:
- Ground every claim in data from your tools. Never invent numbers. If data is missing, say so.
- Statistics come from run_correlations and get_sleep_analysis; you translate them into plain language. Correlation is not causation — propose experiments to verify.
- Be specific and brief. "HRV 42 vs your 30-day median 51" beats "your HRV is a bit low".
- Intervene at the right moment: schedule_push for timed nudges, set_shield_policy nightly for screen control scaled to sleep debt.
- Use remember for anything worth knowing next week: discovered patterns, preferences, whether advice was followed, experiment outcomes.
- Tone: a sharp, warm coach. No corporate wellness fluff. No emoji.

Current time: ${clock.dateStr} ${String(clock.hour).padStart(2, "0")}:${String(clock.minute).padStart(2, "0")} (${config.userTimezone}).

Long-term memory:
${await memoryBlock()}

Active experiments:
${await activeExperimentsBlock()}`;
}

// ---------- Agent loop ----------

export async function runAgent(
  userMessage: string,
  priorMessages: Anthropic.MessageParam[] = [],
  maxTurns = 12,
): Promise<string> {
  const anthropic = client();
  const system = await systemPrompt();
  const messages: Anthropic.MessageParam[] = [...priorMessages, { role: "user", content: userMessage }];

  for (let turn = 0; turn < maxTurns; turn++) {
    const res = await anthropic.messages.create({
      model: config.anthropic.model,
      max_tokens: 2000,
      system,
      tools: TOOLS,
      messages,
    });

    if (res.stop_reason !== "tool_use") {
      return res.content
        .filter((b): b is Anthropic.TextBlock => b.type === "text")
        .map((b) => b.text)
        .join("\n")
        .trim();
    }

    messages.push({ role: "assistant", content: res.content });
    const toolResults: Anthropic.ToolResultBlockParam[] = [];
    for (const block of res.content) {
      if (block.type !== "tool_use") continue;
      let result: unknown;
      try {
        result = await runTool(block.name, block.input);
      } catch (e) {
        result = { error: String(e) };
      }
      toolResults.push({
        type: "tool_result",
        tool_use_id: block.id,
        content: JSON.stringify(result).slice(0, 30_000),
      });
    }
    messages.push({ role: "user", content: toolResults });
  }
  return "I ran out of thinking budget — try again.";
}

// ---------- High-level jobs ----------

export async function saveAgentMessage(
  kind: string,
  content: string,
  meta?: unknown,
): Promise<void> {
  await query(`INSERT INTO agent_messages (kind, content, meta) VALUES ($1, $2, $3)`, [
    kind,
    content,
    meta === undefined ? null : JSON.stringify(meta),
  ]);
}

/**
 * Everything the on-device Apple Foundation Models agent needs to assemble the
 * exact same system prompt that {@link systemPrompt} builds server-side. The
 * device fetches this so the on-device persona matches the Claude persona.
 */
export async function agentContext(): Promise<{
  systemPrompt: string;
  memory: string;
  experiments: string;
  clock: { dateStr: string; hour: number; minute: number; timezone: string };
}> {
  const clock = userClock();
  return {
    systemPrompt: await systemPrompt(),
    memory: await memoryBlock(),
    experiments: await activeExperimentsBlock(),
    clock: {
      dateStr: clock.dateStr,
      hour: clock.hour,
      minute: clock.minute,
      timezone: config.userTimezone,
    },
  };
}

export async function morningBriefing(): Promise<string> {
  const text = await runAgent(
    `Generate my morning briefing. Steps:
1. Pull last night's sleep + today's readiness (query_metrics over ~14 days for context).
2. Get sleep analysis (debt + optimal bedtime).
3. Get today's calendar and assess the day's load.
4. Synthesize: how I slept vs my norms, what today demands, ONE concrete recommendation for today (training intensity, deep-work timing, or recovery), and when I should be in bed tonight given tomorrow's first event.
5. If there's an active experiment, remind me of today's task in one line.
6. schedule_push a bedtime nudge for tonight at (optimal bedtime - 45 min), and set_shield_policy scaled to my sleep debt.
Keep the briefing under 120 words. Plain text, no markdown headers.`,
  );
  await saveAgentMessage("briefing", text);
  return text;
}

export async function eveningWinddown(): Promise<string> {
  const text = await runAgent(
    `Generate my evening wind-down message (sent ~21:00). Look at today's activity, stress minutes, screen time so far, and tomorrow's first calendar event. Tell me: when to be in bed tonight and why (one data point), and one thing to avoid in the next 2 hours based on my discovered patterns. Under 60 words. Plain text.`,
  );
  await saveAgentMessage("winddown", text);
  return text;
}

export async function weeklyReport(): Promise<string> {
  const text = await runAgent(
    `Generate my weekly life report (Sunday evening). Steps:
1. query_metrics for the key outcomes over 28 days; compare this week vs the previous three.
2. run_correlations and surface the 2-3 strongest patterns in plain language.
3. Review active experiments (evaluate_experiment if past end date) and report results honestly, including no-effects.
4. remember anything newly learned.
5. If there is no active experiment, propose_experiment for the most promising lever found.
Structure: "This week", "Patterns", "Experiment", "Next week". Under 250 words.`,
  );
  await saveAgentMessage("weekly", text);
  return text;
}

export async function chat(userText: string): Promise<string> {
  // Rebuild short chat history for continuity.
  const hist = await query<{ kind: string; content: string }>(
    `SELECT kind, content FROM agent_messages
     WHERE kind IN ('chat_user','chat_assistant') ORDER BY created_at DESC LIMIT 12`,
  );
  const prior: Anthropic.MessageParam[] = hist.rows
    .reverse()
    .map((m) => ({ role: m.kind === "chat_user" ? ("user" as const) : ("assistant" as const), content: m.content }));

  await saveAgentMessage("chat_user", userText);
  const reply = await runAgent(userText, prior);
  await saveAgentMessage("chat_assistant", reply);
  return reply;
}
