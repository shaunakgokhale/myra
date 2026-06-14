# Myra backend

TypeScript (Hono) service that powers the Myra iOS app: Oura OAuth + webhooks, a unified daily metrics timeline in Postgres, a statistics engine (lagged correlations, sleep debt, optimal bedtime), a Claude agent with long-term memory, scheduled briefings, and APNs push.

## Deploy on Railway

1. Create a Railway project with a **Postgres** plugin and a service pointing at this `backend/` directory.
2. Set environment variables:

| Variable | Required | Description |
|---|---|---|
| `DATABASE_URL` | yes | Provided by Railway Postgres |
| `BASE_URL` | yes | Public URL of this service, e.g. `https://myra-backend.up.railway.app` |
| `APP_TOKEN` | yes | Random secret; the iOS app sends it as `x-app-token` |
| `OURA_CLIENT_ID` / `OURA_CLIENT_SECRET` | yes | From https://cloud.ouraring.com/oauth/applications — set the app's redirect URI to `{BASE_URL}/oauth/callback` |
| `OURA_WEBHOOK_VERIFICATION_TOKEN` | yes | Any random string |
| `ANTHROPIC_API_KEY` | for AI | Claude API key |
| `ANTHROPIC_MODEL` | no | Defaults to `claude-sonnet-4-5` |
| `APNS_KEY_BASE64` | for push | `base64 < AuthKey_XXXX.p8` |
| `APNS_KEY_ID` / `APNS_TEAM_ID` | for push | From the Apple Developer portal |
| `APNS_BUNDLE_ID` | no | Defaults to `com.shaunak.myra` |
| `APNS_PRODUCTION` | no | `false` for Xcode debug builds (sandbox APNs) |
| `USER_TIMEZONE` | no | Defaults to `Europe/Berlin` |
| `LATITUDE` / `LONGITUDE` | no | For weather/daylight enrichment |

3. Open `{BASE_URL}/oauth/start` once (or use the Connect button in the app). This connects Oura, backfills 365 days of history, and creates webhook subscriptions automatically.

## Local development

```bash
cd backend
npm install
DATABASE_URL=postgres://localhost/myra npm run dev
```

## Notable endpoints

- `GET /oauth/start` — begin Oura OAuth
- `GET|POST /webhooks/oura` — webhook verification + events (HMAC verified)
- `GET /api/dashboard` — day matrix + sleep debt + optimal bedtime + latest agent message
- `GET /api/insights` — discovered correlations
- `POST /api/chat` — talk to the agent
- `POST /api/ingest/daily|samples|calendar` — phone uploads
- `GET /api/directives` — shield policy the phone enforces
- `POST /api/admin/briefing|winddown|weekly|backfill|subscribe` — manual triggers

All `/api/*` routes require the `x-app-token` header.
