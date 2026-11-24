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

## Medication reminders

Reminders are dated, local notifications for eligible doses only. The app plans up to 60 pending alerts, looking ahead up to 30 calendar days from today or the future start date of each course. Open the app periodically and after travel to refresh them. Course and device preferences, notification permission, and the signed-in account determine what is eligible. As-needed and unscheduled medications generate no automatic alerts.

Both platforms use generic notification text by default. The account-scoped **Include medicine details** option explicitly permits names and doses in the notification body. The device controls where previews appear. On upgrade, the app clears older pending and delivered notifications on its first launch, resets the old preview preference, and preserves the previous on/off switch only when a session is restored. Android also clears the old schedule after package replacement.

Android restores only future dated NOVA alerts after reboot. Android drops its pending batch on a system time-zone change and rebuilds it at the next foreground refresh. On iOS, already registered alerts use their original instants until NOVA can refresh after travel. An offline same-account refresh can keep a valid existing batch. Remote medication changes on a closed device are picked up when it next refreshes. OS throttling, Focus and inexact Android alarms can delay delivery.

The Android reboot filter reads the pinned notification plugin's cache format. Recheck the filter and device reboot behavior when upgrading that plugin. To rerun its host test with Java 17 or newer, use the commands below from the repository root.

```sh
reminder_test_dir=$(mktemp -d)
javac -d "$reminder_test_dir" \
  mobile/android/app/src/main/java/com/example/nova_health/ReminderRestorePolicy.java \
  mobile/android/app/src/test/java/com/example/nova_health/ReminderRestorePolicyTest.java
java -cp "$reminder_test_dir" com.example.nova_health.ReminderRestorePolicyTest
```

Physical-device verification with synthetic accounts and medicines is still required.

- On Android, deny and revoke notification permission and exact alarm access. Check the inexact fallback and private lock-screen previews with the system's preview settings varied.
- On iOS, test denied permission, foreground banners, lock-screen previews, Focus, and delivery with the app closed. Check the first launch after upgrading with a legacy pending reminder.
- On both, check a future start, an inclusive course end, and an exact interval across midnight and a daylight-saving transition. Change time zones while the app is closed and again while it is active.
- Reboot with both an expired and a future reminder. Confirm the future alert and confirm an expired course does not replay. Sign out, switch synthetic accounts, and disable reminders while a batch is being scheduled. Check both pending alerts and delivered notifications.

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
