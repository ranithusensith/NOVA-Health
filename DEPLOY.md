# Deploy the NOVA backend (about 20 minutes, needs internet once)

The app uses Supabase for login. External AI is optional and disabled by default.

## A. Before you start
1. All code is on GitHub (the final upload). `backend/` must contain `Dockerfile` and `requirements.txt`.
2. Have `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` ready. Review the [external AI privacy deployment requirements](docs/ai-privacy.md#storage-and-deployment) before adding an AI key or enabling Gemini.

## B. Render (free plan)
1. Add the files from this pack: `backend/Dockerfile`, `backend/.dockerignore`, and `render.yaml` at the repo root.
2. Commit and push.
3. render.com -> sign in with GitHub -> New -> Blueprint -> pick the repo -> Apply.
4. Open the new service -> Environment. Set the Supabase URL and publishable key. Leave external AI off until the privacy deployment requirements are met.
5. Wait for "Live". Open `https://<your-service>.onrender.com/health`. Expect `{"data":{"status":"ok"}}`.
6. Free plan sleeps after 15 minutes idle; the first request then takes about 50 seconds.
   Before a demo, open `/health` once to wake it.

## C. Point the app at it
1. In `mobile/dart_defines.json` set `"API_URL": "https://<your-service>.onrender.com"` and `"USE_MOCK_API": "false"`.
2. Run: `flutter run --dart-define-from-file=dart_defines.json`
3. For a release APK: `flutter build apk --release --dart-define-from-file=dart_defines.json`
   The file is `build/app/outputs/flutter-apk/app-release.apk`. Send it to phones and install it.

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
