# Myra — an autonomous health agent

Not a dashboard. Myra runs a loop over your life:

**Observe → Discover → Intervene → Verify → Remember**

- **Observe** — Oura (sleep, HRV, readiness, stress, SpO2, workouts, via OAuth + webhooks), HealthKit (steps, workouts, resting HR, caffeine, alcohol, mindfulness), your calendar (meeting load, first-event time), weather/daylight.
- **Discover** — a statistics engine (lagged Pearson correlations, p-values, n≥10) finds *your* patterns; Claude narrates them, it never invents them.
- **Intervene** — morning briefing & evening wind-down pushes, a computed bedtime nudge, Screen Time app shielding whose strictness scales with your sleep debt, stress-spike breathing nudges, agent-proposed recovery blocks written into your calendar.
- **Verify** — n=1 experiments with compliance logging and Cohen's d effect sizes.
- **Remember** — long-term agent memory: what was tried, what worked, what you ignored.

## Repo layout

- `backend/` — TypeScript (Hono) service for Railway: Oura OAuth + webhooks, Postgres timeline, stats engine, Claude agent, APNs, schedulers. See `backend/README.md` for env vars.
- `myra/` — SwiftUI iOS app: Today, Trends, Coach (chat), Lab (patterns + experiments), Settings; HealthKit/EventKit/Screen Time sensors; 4-7-8 breathing; Siri App Intents.
- `myraWidgets/` — Home Screen + Lock Screen widgets (readiness, sleep debt).

## Setup, in order

1. **Deploy the backend** on Railway with a Postgres plugin (see `backend/README.md`). Note the public URL.
2. **Oura application** at https://cloud.ouraring.com/oauth/applications — set redirect URI to `{BASE_URL}/oauth/callback`, put client ID/secret in Railway env.
3. **Claude key** → `ANTHROPIC_API_KEY` env.
4. **APNs key** (Apple Developer → Keys → APNs) → `APNS_KEY_BASE64`, `APNS_KEY_ID`, `APNS_TEAM_ID`.
5. **Run the app** from Xcode on your iPhone. Enter the backend URL + `APP_TOKEN` on first launch, tap Connect Oura, grant HealthKit / Calendar / Screen Time, pick the apps to shield at wind-down.
6. In Xcode, Signing & Capabilities should show HealthKit, App Groups (`group.com.shaunak.myra`), Family Controls, and Push Notifications (all declared in `myra/myra.entitlements`).

## Notes

- Oura killed personal access tokens (Dec 2025); OAuth + webhooks is the only path, which is why the backend exists.
- The Family Controls (Screen Time) entitlement works for development builds; App Store distribution would require Apple's approval for the distribution entitlement.
- Screen Time *usage metrics* are not exportable via public API; Myra enforces shields rather than pretending to read minutes. Late-night usage correlations come from the data sources that are readable.
