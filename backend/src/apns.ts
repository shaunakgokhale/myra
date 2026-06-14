import http2 from "node:http2";
import crypto from "node:crypto";
import { config } from "./config.js";
import { query } from "./db.js";

/** Minimal token-based APNs client (no external dependencies). */

let cachedJwt: { token: string; issuedAt: number } | null = null;

function apnsJwt(): string {
  // APNs tokens are valid 20-60 min; reuse for 45.
  if (cachedJwt && Date.now() - cachedJwt.issuedAt < 45 * 60_000) return cachedJwt.token;

  const key = Buffer.from(config.apns.keyBase64, "base64").toString("utf8");
  const header = Buffer.from(JSON.stringify({ alg: "ES256", kid: config.apns.keyId })).toString("base64url");
  const claims = Buffer.from(
    JSON.stringify({ iss: config.apns.teamId, iat: Math.floor(Date.now() / 1000) }),
  ).toString("base64url");
  const unsigned = `${header}.${claims}`;
  const signature = crypto
    .createSign("SHA256")
    .update(unsigned)
    .sign({ key, dsaEncoding: "ieee-p1363" })
    .toString("base64url");
  const token = `${unsigned}.${signature}`;
  cachedJwt = { token, issuedAt: Date.now() };
  return token;
}

export function apnsConfigured(): boolean {
  return Boolean(config.apns.keyBase64 && config.apns.keyId && config.apns.teamId);
}

type PushType = "alert" | "background";

async function sendToToken(deviceToken: string, payload: object, pushType: PushType = "alert"): Promise<number> {
  const host = config.apns.production
    ? "https://api.push.apple.com"
    : "https://api.sandbox.push.apple.com";

  return new Promise((resolve, reject) => {
    const client = http2.connect(host);
    client.on("error", reject);
    const req = client.request({
      ":method": "POST",
      ":path": `/3/device/${deviceToken}`,
      authorization: `bearer ${apnsJwt()}`,
      "apns-topic": config.apns.bundleId,
      "apns-push-type": pushType,
      // Background pushes must use priority 5; alerts stay at 10.
      "apns-priority": pushType === "background" ? "5" : "10",
      "content-type": "application/json",
    });
    let status = 0;
    req.on("response", (headers) => {
      status = Number(headers[":status"] ?? 0);
    });
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      client.close();
      if (status >= 400) console.error(`APNs ${status}: ${body}`);
      resolve(status);
    });
    req.on("error", (e) => {
      client.close();
      reject(e);
    });
    req.end(JSON.stringify(payload));
  });
}

export async function pushToAllDevices(
  title: string,
  body: string,
  category?: string,
  extra?: Record<string, unknown>,
): Promise<void> {
  if (!apnsConfigured()) {
    console.log(`[push skipped, APNs not configured] ${title}: ${body}`);
    return;
  }
  const devices = await query<{ token: string }>(`SELECT token FROM devices`);
  const payload = {
    aps: {
      alert: { title, body },
      sound: "default",
      ...(category ? { category } : {}),
    },
    ...extra,
  };
  for (const d of devices.rows) {
    try {
      const status = await sendToToken(d.token, payload);
      if (status === 410) {
        await query(`DELETE FROM devices WHERE token = $1`, [d.token]);
      }
    } catch (e) {
      console.error("APNs send failed:", e);
    }
  }
}

/**
 * Silent/background push that wakes the app to run the on-device Apple
 * Foundation Models agent for a scheduled job. Delivers no user-visible alert;
 * the device posts a local notification once generation completes. Returns the
 * number of devices the wake was sent to.
 */
export async function wakeAllDevices(kind: string): Promise<number> {
  if (!apnsConfigured()) {
    console.log(`[wake skipped, APNs not configured] kind=${kind}`);
    return 0;
  }
  const devices = await query<{ token: string }>(`SELECT token FROM devices`);
  const payload = { aps: { "content-available": 1 }, kind };
  let sent = 0;
  for (const d of devices.rows) {
    try {
      const status = await sendToToken(d.token, payload, "background");
      if (status === 410) {
        await query(`DELETE FROM devices WHERE token = $1`, [d.token]);
      } else if (status < 400) {
        sent++;
      }
    } catch (e) {
      console.error("APNs wake failed:", e);
    }
  }
  return sent;
}
