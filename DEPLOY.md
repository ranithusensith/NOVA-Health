# Deploy the NOVA backend (about 20 minutes, needs internet once)

The app uses Supabase for login. External AI is optional and disabled by default.

## A. Before you start
1. All code is on GitHub (the final upload). `backend/` must contain `Dockerfile` and `requirements.txt`.
2. Have `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` ready. Review the [external AI privacy deployment requirements](docs/ai-privacy.md#storage-and-deployment) before adding an AI key or enabling Gemini.
3. Set up the database using the [Supabase migration order](docs/database-setup.md).

## B. Render (free plan)
1. Add the files from this pack: `backend/Dockerfile`, `backend/.dockerignore`, and `render.yaml` at the repo root.
2. Commit and push.
3. render.com -> sign in with GitHub -> New -> Blueprint -> pick the repo -> Apply.
4. Open the new service -> Environment. Set the Supabase URL and publishable key. Leave external AI off until the privacy deployment requirements are met.
5. Wait for "Live". Open `https://<your-service>.onrender.com/health`. Expect `{"data":{"status":"ok"}}`.
6. Free plan sleeps after 15 minutes idle; the first request then takes about 50 seconds.
   Before a demo, open `/health` once to wake it.

## C. Point the app at it

For a real build, copy `mobile/dart_defines.example.json` to an ignored local configuration file. Set `SUPABASE_URL` and `API_URL` to the approved HTTPS endpoints, use the Supabase project's publishable key (or a legacy `anon` key), and set `USE_MOCK_API` to `false`. Keep service-role keys and other secrets in server configuration. Android and iOS validate these settings before compiling Profile or Release, and NOVA checks them again before initializing Supabase. Debug builds allow HTTP only for loopback development endpoints, including the Android emulator's `10.0.2.2` alias.

From `mobile/`, run `flutter build apk --release --dart-define-from-file=dart_defines.json` for the Android release artifact. Release APKs are unsigned until the team supplies approved release signing. For an unsigned iOS compile check, run `flutter build ios --release --no-codesign --dart-define-from-file=dart_defines.json`. Use the approved signing and provisioning setup for device installs. The configuration check validates URL and key format. The release operator still needs to verify that the endpoints and key belong to the intended environment.

### Offline scan demos

From `mobile/`, run `flutter run --debug --dart-define=USE_MOCK_API=true`. Demo mode opens a labeled screen with bundled synthetic prescription, lab, and meal examples. Demo saves stay in memory. The demo needs no login or network configuration, and never initializes Supabase, requests access to the photo library, or sends anything to an AI provider. To return to real mode, stop the demo and start a new build with valid real settings. Demo records do not carry over. Use a dedicated device or simulator if you need to keep demo installs separate from a real installation.

If a demonstration needs real API behavior, use synthetic accounts in a disposable environment with its own backend and Supabase project. Apply the migrations there. Review the final artifact and its signing before distribution.

## D. Real SMS for SOS (optional)
1. twilio.com -> trial account (free credit). Trial accounts can only text numbers you verify in the console.
2. In Render set: `NOTIFY_PROVIDER=twilio`, `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM` (your Twilio number).
3. Add a verified number as an emergency contact in the app and send an SOS.
Without Twilio the app still works: it opens the phone's messages app with the alert ready to send.

## E. If something fails
- 401 from the app: wrong `SUPABASE_URL` or key on the server.
- "AI service is busy": check capacity and quota for the approved Gemini project. Keep the provider disabled while reviewing a different project or model.
- "External AI is disabled": see the [provider approval and database requirements](docs/ai-privacy.md#storage-and-deployment).
- 502 on first request: service was asleep; retry after a minute.
- Docker build error: paste the last 20 lines of the Render build log.
