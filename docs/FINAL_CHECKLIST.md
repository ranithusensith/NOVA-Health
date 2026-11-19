# Final checklist

## App
1. App icon: use the `flutter_launcher_icons` package with a 1024x1024 PNG (`dev_dependencies`, then `dart run flutter_launcher_icons`).
2. Splash: keep the default or use `flutter_native_splash`.
3. Application ID: change `com.example.nova_health` in `android/app/build.gradle.kts` (namespace and applicationId) and in the manifest package paths.
4. Dark mode, large text (Settings -> Font size) and a small phone: check every screen.
5. `flutter analyze` has no errors; `flutter test` passes.
6. Release build: `flutter build apk --release --dart-define-from-file=dart_defines.json`.

## Backend
1. `python -m pytest -q` passes.
2. Deployed and `/health` works (see DEPLOY.md).
3. `ALLOWED_ORIGINS` set if a web client is added.
4. No `.env`, `dart_defines.json`, keys or real health data in Git (`git ls-files | grep -E "env|dart_defines"` should show only the `.example` files).

## Report
1. Architecture and API contract (done in `docs/`).
2. Evaluation chapter: `docs/EVALUATION.md`.
3. Safety chapter: `docs/SAFETY_DESIGN.md`.
4. Limitations and future work (location in SOS, Sinhala and Tamil, clinician review, paid AI tier).
5. Team contributions: frontend team (Flutter UI) and Sensith (backend, database, AI, integrations).

## Upload to GitHub (when you have internet)
1. `cd /Users/ranithu/Downloads/NOVA-Health`
2. `git status` and check no secrets are listed.
3. `git checkout -b feature/full-build`
4. `git add .` then `git commit -m "Full app, backend, evaluation and docs"`
5. `git push -u origin feature/full-build`, then open a Pull Request.
