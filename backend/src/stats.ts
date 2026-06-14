import { query } from "./db.js";
import { daysAgoStr } from "./config.js";

/**
 * The discovery engine. Real statistics over the unified timeline —
 * the LLM narrates findings, it does not invent them.
 */

export interface DayRow {
  day: string;
  [metric: string]: number | string | null;
}

/** Pivot the metrics table into a day x metric matrix for the last N days. */
export async function loadDailyMatrix(days = 120): Promise<DayRow[]> {
  const r = await query<{ day: string; metric: string; value: number }>(
    `SELECT to_char(day, 'YYYY-MM-DD') AS day, metric, value
     FROM metrics
     WHERE day >= $1 AND value IS NOT NULL
     ORDER BY day`,
    [daysAgoStr(days)],
  );
  const byDay = new Map<string, DayRow>();
  for (const row of r.rows) {
    let d = byDay.get(row.day);
    if (!d) {
      d = { day: row.day };
      byDay.set(row.day, d);
    }
    d[row.metric] = Number(row.value);
  }
  return [...byDay.values()].sort((a, b) => (a.day < b.day ? -1 : 1));
}

function pairs(matrix: DayRow[], x: string, y: string, lagDays: number): Array<[number, number]> {
  // lagDays = 1 means: x on day D vs y on day D+1 (does x predict tomorrow's y?)
  const out: Array<[number, number]> = [];
  const idx = new Map(matrix.map((r, i) => [r.day, i]));
  for (const row of matrix) {
    const xv = row[x];
    if (typeof xv !== "number") continue;
    const i = idx.get(row.day)!;
    const target = matrix[i + lagDays];
    if (!target) continue;
    // Ensure target is actually lagDays calendar days later.
    const expected = new Date(new Date(row.day + "T00:00:00Z").getTime() + lagDays * 86400_000)
      .toISOString()
      .slice(0, 10);
    if (target.day !== expected) continue;
    const yv = target[y];
    if (typeof yv !== "number") continue;
    out.push([xv, yv]);
  }
  return out;
}

export interface Correlation {
  x: string;
  y: string;
  lag: number;
  n: number;
  r: number;
  p: number;
}

export function pearson(data: Array<[number, number]>): { r: number; p: number; n: number } {
  const n = data.length;
  if (n < 8) return { r: 0, p: 1, n };
  const mx = data.reduce((s, [a]) => s + a, 0) / n;
  const my = data.reduce((s, [, b]) => s + b, 0) / n;
  let sxy = 0, sxx = 0, syy = 0;
  for (const [a, b] of data) {
    sxy += (a - mx) * (b - my);
    sxx += (a - mx) ** 2;
    syy += (b - my) ** 2;
  }
  if (sxx === 0 || syy === 0) return { r: 0, p: 1, n };
  const r = sxy / Math.sqrt(sxx * syy);
  // Two-sided p-value via t distribution approximation.
  const t = Math.abs(r) * Math.sqrt((n - 2) / Math.max(1e-12, 1 - r * r));
  const p = 2 * (1 - studentTCdf(t, n - 2));
  return { r, p, n };
}

/** Approximate Student-t CDF (good enough for screening). */
function studentTCdf(t: number, df: number): number {
  // Hill's approximation via normal correction.
  const x = t * (1 - 1 / (4 * df)) / Math.sqrt(1 + (t * t) / (2 * df));
  return normCdf(x);
}

function normCdf(x: number): number {
  return 0.5 * (1 + erf(x / Math.SQRT2));
}

function erf(x: number): number {
  const sign = x < 0 ? -1 : 1;
  x = Math.abs(x);
  const a1 = 0.254829592, a2 = -0.284496736, a3 = 1.421413741, a4 = -1.453152027, a5 = 1.061405429, p = 0.3275911;
  const t = 1 / (1 + p * x);
  const y = 1 - ((((a5 * t + a4) * t + a3) * t + a2) * t + a1) * t * Math.exp(-x * x);
  return sign * y;
}

/** Inputs: things you do / context. Outcomes: how your body responds. */
const OUTCOME_METRICS = [
  "sleep_score", "readiness_score", "avg_hrv", "lowest_hr_sleep", "deep_sleep_s",
  "rem_sleep_s", "total_sleep_s", "sleep_efficiency", "sleep_latency_s", "stress_high_s",
];

const INPUT_HINTS = [
  "steps", "active_calories", "sedentary_time_s", "workout_", "session_", "tag_",
  "screen_", "meeting_", "caffeine", "alcohol", "temp_max_c", "daylight_s", "sunshine_s",
  "bedtime_start_min", "first_event_min", "calendar_busy_s", "mindful_min", "exercise_min",
];

export async function discoverCorrelations(days = 120, maxResults = 25): Promise<Correlation[]> {
  const matrix = await loadDailyMatrix(days);
  if (matrix.length < 14) return [];

  const allMetrics = new Set<string>();
  for (const row of matrix) for (const k of Object.keys(row)) if (k !== "day") allMetrics.add(k);

  const inputs = [...allMetrics].filter((m) => INPUT_HINTS.some((h) => m.startsWith(h) || m === h));
  const results: Correlation[] = [];

  for (const x of inputs) {
    for (const y of OUTCOME_METRICS) {
      if (!allMetrics.has(y) || x === y) continue;
      for (const lag of [0, 1]) {
        // lag 0 for same-day signals (bedtime -> that night's sleep);
        // lag 1 for next-day effects (workout -> tomorrow's HRV).
        const { r, p, n } = pearson(pairs(matrix, x, y, lag));
        if (n >= 10 && Math.abs(r) >= 0.3 && p < 0.05) {
          results.push({ x, y, lag, n, r: round3(r), p: round3(p) });
        }
      }
    }
  }
  results.sort((a, b) => Math.abs(b.r) - Math.abs(a.r));
  return results.slice(0, maxResults);
}

function round3(v: number): number {
  return Math.round(v * 1000) / 1000;
}

// ---------- Sleep debt & optimal window ----------

export interface SleepDebt {
  /** Hours of debt accumulated over the last 14 days vs personal need. */
  debtHours: number;
  personalNeedHours: number;
  last7AvgHours: number;
}

export async function sleepDebt(): Promise<SleepDebt | null> {
  const matrix = await loadDailyMatrix(90);
  const sleeps = matrix.map((r) => r.total_sleep_s).filter((v): v is number => typeof v === "number");
  if (sleeps.length < 10) return null;

  // Personal need: 90th percentile of the last 90 days (your "fully rested" nights),
  // clamped to a sane range.
  const sorted = [...sleeps].sort((a, b) => a - b);
  const p90 = sorted[Math.floor(sorted.length * 0.9)];
  const needH = Math.min(9, Math.max(6.5, p90 / 3600));

  const recent = matrix.slice(-14);
  let debt = 0;
  for (const r of recent) {
    if (typeof r.total_sleep_s === "number") {
      debt += Math.max(0, needH - r.total_sleep_s / 3600);
    }
  }
  const last7 = matrix.slice(-7).map((r) => r.total_sleep_s).filter((v): v is number => typeof v === "number");
  const last7Avg = last7.length ? last7.reduce((s, v) => s + v, 0) / last7.length / 3600 : 0;

  return {
    debtHours: Math.round(debt * 10) / 10,
    personalNeedHours: Math.round(needH * 10) / 10,
    last7AvgHours: Math.round(last7Avg * 10) / 10,
  };
}

export interface OptimalWindow {
  /** Best bedtime as minutes-past-midnight in the normalized scale (1080 = 18:00, 1440 = 00:00). */
  bestBedtimeMin: number;
  bestBedtimeLabel: string;
  avgScoreInWindow: number;
  sampleSize: number;
}

export async function optimalBedtimeWindow(): Promise<OptimalWindow | null> {
  const matrix = await loadDailyMatrix(120);
  // bedtime on day D vs sleep_score on day D (Oura assigns the night to the wake day... the
  // sleep doc's `day` is the wake day, and bedtime_start belongs to the same doc, so lag 0).
  const data = pairs(matrix, "bedtime_start_min", "sleep_score", 0);
  if (data.length < 14) return null;

  // 30-minute bins.
  const bins = new Map<number, number[]>();
  for (const [bt, score] of data) {
    const bin = Math.round(bt / 30) * 30;
    if (!bins.has(bin)) bins.set(bin, []);
    bins.get(bin)!.push(score);
  }
  let best: { bin: number; avg: number; n: number } | null = null;
  for (const [bin, scores] of bins) {
    if (scores.length < 3) continue;
    const avg = scores.reduce((s, v) => s + v, 0) / scores.length;
    if (!best || avg > best.avg) best = { bin, avg, n: scores.length };
  }
  if (!best) return null;

  const minutes = best.bin % 1440;
  const h = Math.floor(minutes / 60);
  const mm = String(minutes % 60).padStart(2, "0");
  return {
    bestBedtimeMin: best.bin,
    bestBedtimeLabel: `${String(h).padStart(2, "0")}:${mm}`,
    avgScoreInWindow: Math.round(best.avg * 10) / 10,
    sampleSize: best.n,
  };
}

// ---------- Experiment evaluation ----------

export interface EffectResult {
  baselineMean: number;
  experimentMean: number;
  deltaPct: number;
  cohensD: number;
  baselineN: number;
  experimentN: number;
  verdict: "improved" | "worsened" | "no_clear_effect";
}

export async function evaluateEffect(
  metric: string,
  baselineStart: string,
  baselineEnd: string,
  expStart: string,
  expEnd: string,
): Promise<EffectResult | null> {
  const r = await query<{ day: string; value: number }>(
    `SELECT to_char(day,'YYYY-MM-DD') AS day, value FROM metrics
     WHERE metric = $1 AND day BETWEEN $2 AND $3 AND value IS NOT NULL`,
    [metric, baselineStart, expEnd],
  );
  const baseline = r.rows.filter((x) => x.day >= baselineStart && x.day <= baselineEnd).map((x) => Number(x.value));
  const exp = r.rows.filter((x) => x.day >= expStart && x.day <= expEnd).map((x) => Number(x.value));
  if (baseline.length < 5 || exp.length < 5) return null;

  const mean = (a: number[]) => a.reduce((s, v) => s + v, 0) / a.length;
  const sd = (a: number[], m: number) => Math.sqrt(a.reduce((s, v) => s + (v - m) ** 2, 0) / Math.max(1, a.length - 1));
  const mb = mean(baseline), me = mean(exp);
  const pooled = Math.sqrt(
    ((baseline.length - 1) * sd(baseline, mb) ** 2 + (exp.length - 1) * sd(exp, me) ** 2) /
      Math.max(1, baseline.length + exp.length - 2),
  );
  const d = pooled === 0 ? 0 : (me - mb) / pooled;

  return {
    baselineMean: round3(mb),
    experimentMean: round3(me),
    deltaPct: round3(((me - mb) / Math.abs(mb || 1)) * 100),
    cohensD: round3(d),
    baselineN: baseline.length,
    experimentN: exp.length,
    verdict: Math.abs(d) < 0.3 ? "no_clear_effect" : d > 0 ? "improved" : "worsened",
  };
}
