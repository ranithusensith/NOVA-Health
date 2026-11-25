# Deploy NOVA Health

Use a disposable staging environment and synthetic accounts for verification before any patient use.

## Backend and database

- Create a Supabase project with Auth enabled. Apply [migrations 001–016](docs/database-setup.md) with an approved migration owner. Confirm signup, email confirmation, restrictive RLS, owner-only access, and restoration procedures. Provision the protected medication-review key after migration 011, and set the matching server-only `MEDICATION_REVIEW_SIGNING_KEY`.
- Deploy the FastAPI service using `backend/Dockerfile`. Configure the approved HTTPS `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`. Confirm `GET /health` returns `{"data":{"status":"ok"}}`. Check cold-start and response timing on the chosen host before a demonstration.
- If using the Render blueprint, review `autoDeploy` and configure explicit release approval before linking a branch. Review permitted web origins, HTTPS termination, disabled request-body capture, OCR dependencies, and safe temporary file and error logging. See [backend environment settings](backend/.env.example).
- Register the [daily-report Cron job](docs/requirements/p2-2-automated-daily-reports.md#scheduler-setup) and the [legacy-chat retention job](docs/database-setup.md#h11-legacy-chat-retention) only in approved environments. Verify job ownership, timing, retry, catch-up, and retention using synthetic data.

## Provider configuration

- Gemini stays off until the operator approves its project, paid service, disclosure, access, telemetry, and retention. Use the [external AI privacy requirements](docs/ai-privacy.md#storage-and-deployment) to provision the approved model and server-only key. User consent is still required.
- Open-Meteo stays off until `WEATHER_PROVIDER` is configured. Use the approved public or customer mode and keep any customer API key on the backend. City forecasts include freshness and source. Outdoor notices are opt-in, foreground-only, and generic in the notification tray. [Weather notice scope](docs/requirements/p2-3-safe-contextual-health-alerts.md)
- Keep `NOTIFY_PROVIDER=log` for a synthetic demo. Use SOS simulation and leave the dialer and SMS composer inactive. Enabling Twilio for a real environment requires approved sender, account and credentials, delivery verification, and a reviewed fallback policy.

## Android and iOS

Use an ignored copy of `mobile/dart_defines.example.json` with the approved HTTPS `SUPABASE_URL` and `API_URL`, the Supabase publishable key, and `USE_MOCK_API=false`. Profile and release builds validate the configuration. Keep provider keys and server credentials out of Flutter.

From `mobile/`, compile with `flutter build apk --release --dart-define-from-file=dart_defines.json` and `flutter build ios --release --no-codesign --dart-define-from-file=dart_defines.json`. Apply approved Android signing and iOS provisioning before installing release artifacts. Verify the iOS HealthKit entitlement, Android Health Connect grants, and native camera, notifications, reboot, and account-switch behavior on signed physical devices.

Session and PKCE credentials use Android encrypted preferences backed by the platform Keystore and iOS Keychain with device-only access. Android excludes shared preferences from cloud backup and device transfer, including legacy token preferences and notification caches. Device-local preferences may need to be set again on a new device. On upgrade, a matching legacy session must be confirmed by the configured Supabase Auth project before migration. An invalid, expired, or offline legacy session requires sign-in again. Earlier backups are subject to their own retention policies. Verify upgrade, reinstalls, restored devices, and sign-out on staging devices.

## Offline demonstration

`flutter run --debug --dart-define=USE_MOCK_API=true` opens a labeled offline sample-scan screen with bundled synthetic prescription, lab, and meal examples. Saves are session-only. The full walkthrough uses a separate configured staging build and synthetic accounts. [Rehearsal script](docs/DEMO_SCRIPT.md)
