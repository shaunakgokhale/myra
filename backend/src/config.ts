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
