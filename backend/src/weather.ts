import { config, daysAgoStr } from "./config.js";
import { upsertMetric } from "./db.js";

/**
 * Daily weather + daylight from Open-Meteo (free, no API key).
 * Stored into the unified timeline so the stats engine can correlate
 * mood/sleep/HRV with temperature, daylight, and sunshine.
 */
export async function syncWeather(daysBack = 7): Promise<number> {
  const u = new URL("https://api.open-meteo.com/v1/forecast");
  u.searchParams.set("latitude", String(config.latitude));
  u.searchParams.set("longitude", String(config.longitude));
  u.searchParams.set("daily", "temperature_2m_max,temperature_2m_min,daylight_duration,sunshine_duration,precipitation_sum");
  u.searchParams.set("timezone", config.userTimezone);
  u.searchParams.set("start_date", daysAgoStr(daysBack));
  u.searchParams.set("end_date", daysAgoStr(0));

  const res = await fetch(u);
  if (!res.ok) throw new Error(`open-meteo failed: ${res.status}`);
  const json = (await res.json()) as any;
  const days: string[] = json.daily?.time ?? [];

  for (let i = 0; i < days.length; i++) {
    const day = days[i];
    await upsertMetric(day, "weather", "temp_max_c", json.daily.temperature_2m_max?.[i] ?? null);
    await upsertMetric(day, "weather", "temp_min_c", json.daily.temperature_2m_min?.[i] ?? null);
    await upsertMetric(day, "weather", "daylight_s", json.daily.daylight_duration?.[i] ?? null);
    await upsertMetric(day, "weather", "sunshine_s", json.daily.sunshine_duration?.[i] ?? null);
    await upsertMetric(day, "weather", "precipitation_mm", json.daily.precipitation_sum?.[i] ?? null);
  }
  return days.length;
}
