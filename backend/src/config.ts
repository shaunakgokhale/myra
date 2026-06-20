function env(name: string, fallback?: string): string {
  const v = process.env[name];
  if (v !== undefined && v !== "") return v;
  if (fallback !== undefined) return fallback;
  return "";
}

export const config = {
  port: Number(env("PORT", "8080")),
  /** Public base URL of this server, e.g. https://myra-backend.up.railway.app */
  baseUrl: env("BASE_URL", `http://localhost:${env("PORT", "8080")}`),
  databaseUrl: env("DATABASE_URL"),
  /** Shared secret between the iOS app and this backend. */
  appToken: env("APP_TOKEN"),
  userTimezone: env("USER_TIMEZONE", "Europe/Berlin"),
  /** Location for weather/daylight enrichment. */
  latitude: Number(env("LATITUDE", "52.52")),
  longitude: Number(env("LONGITUDE", "13.405")),

  oura: {
    clientId: env("OURA_CLIENT_ID"),
    clientSecret: env("OURA_CLIENT_SECRET"),
    webhookVerificationToken: env("OURA_WEBHOOK_VERIFICATION_TOKEN", "myra-verification-token"),
    scopes: env("OURA_SCOPES", "email personal daily heartrate workout tag session spo2"),
  },

  anthropic: {
    apiKey: env("ANTHROPIC_API_KEY"),
    model: env("ANTHROPIC_MODEL", "claude-sonnet-4-5"),
  },

  apns: {
    /** Base64-encoded contents of the .p8 key file. */
    keyBase64: env("APNS_KEY_BASE64"),
    keyId: env("APNS_KEY_ID"),
    teamId: env("APNS_TEAM_ID"),
    bundleId: env("APNS_BUNDLE_ID", "com.shaunak.myra"),
    production: env("APNS_PRODUCTION", "false") === "true",
  },
};

export function userNow(): Date {
  return new Date();
}

/** Returns {hour, minute, weekday(0=Sun), dateStr YYYY-MM-DD} in the user's timezone. */
export function userClock(d = new Date()) {
  const fmt = new Intl.DateTimeFormat("en-CA", {
    timeZone: config.userTimezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    weekday: "short",
  });
  const parts = Object.fromEntries(fmt.formatToParts(d).map((p) => [p.type, p.value]));
  const weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  return {
    hour: Number(parts.hour === "24" ? "0" : parts.hour),
    minute: Number(parts.minute),
    weekday: weekdays.indexOf(parts.weekday),
    dateStr: `${parts.year}-${parts.month}-${parts.day}`,
  };
}

/** YYYY-MM-DD for N days ago in user's timezone. */
export function daysAgoStr(n: number): string {
  const d = new Date(Date.now() - n * 86400_000);
  return new Intl.DateTimeFormat("en-CA", { timeZone: config.userTimezone }).format(d);
}

/** UTC offset (e.g. "+02:00") that `tz` was at on the given YYYY-MM-DD, midday to dodge DST edges. */
export function tzOffset(dateStr: string, tz = config.userTimezone): string {
  const probe = new Date(`${dateStr}T12:00:00Z`);
  const name = new Intl.DateTimeFormat("en-US", { timeZone: tz, timeZoneName: "longOffset" })
    .formatToParts(probe)
    .find((p) => p.type === "timeZoneName")?.value ?? "GMT+00:00";
  const m = name.match(/GMT([+-]\d{2}:?\d{2})?/);
  if (!m || !m[1]) return "+00:00";
  return m[1].includes(":") ? m[1] : `${m[1].slice(0, 3)}:${m[1].slice(3)}`;
}

/** ISO-8601 start/end datetimes spanning one local calendar day, incl. UTC offset. */
export function dayBoundsIso(dateStr: string, tz = config.userTimezone): { start: string; end: string } {
  const next = new Intl.DateTimeFormat("en-CA", { timeZone: tz }).format(
    new Date(new Date(`${dateStr}T12:00:00Z`).getTime() + 86400_000),
  );
  return {
    start: `${dateStr}T00:00:00${tzOffset(dateStr, tz)}`,
    end: `${next}T00:00:00${tzOffset(next, tz)}`,
  };
}
