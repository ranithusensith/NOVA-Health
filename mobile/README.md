# NOVA Health — Mobile app (Flutter)

The NOVA Health iPhone and Android app. It brings medications, sleep, water,
mood and meals into one place, reads prescriptions and meals from photos, and
turns the data into plain-language daily guidance.

Design: Apple Health–inspired, Liquid Glass controls over solid content cards,
light and dark mode. Every AI surface shows "Guidance, not medical advice".

## Run it

Requires Flutter 3.27 or newer.

```bash
cd mobile
flutter pub get
cp dart_defines.example.json dart_defines.json   # then fill in the values
flutter run --dart-define-from-file=dart_defines.json
```

`dart_defines.json` holds the Supabase URL, the **publishable** key and the API
address. It is git-ignored: never commit it.

| Key | What it is |
|---|---|
| `SUPABASE_URL` | Project URL |
| `SUPABASE_KEY` | Publishable key only (never the secret key) |
| `API_URL` | Backend: `http://10.0.2.2:8000` on the Android emulator, `http://127.0.0.1:8000` on the iPhone simulator |
| `USE_MOCK_API` | `"true"` returns sample scan, chat, report and SOS responses so the UI works without the backend |

## Checks

```bash
flutter analyze
flutter test
```

## Screens

| Screen | What it does |
|---|---|
| Login / sign up | Supabase Auth, animated orb, validation |
| Home | Insight from today's numbers, water/sleep/steps rings, next dose with **Mark as taken**, weather tip, one-tap mood |
| Track | Log water, sleep and mood; **Today** and **7-day** history charts with text summaries |
| Medications | Today's timeline (Morning / Afternoon / Evening) with taken, due, upcoming and missed states; add, edit, stop; scan instead |
| Scan | Camera or gallery → prescription or meal is read by the backend → user checks and confirms before anything is saved |
| Assistant | Chat with the health assistant (`POST /api/v1/assistant/chat`), suggestion chips, typing indicator |
| Daily report | Day score, AI summary (`GET /api/v1/reports/daily`), sleep / hydration / nutrition / medications / mood sections, top 3 suggestions, copy report |
| Emergency | Hold-to-send SOS (3 s) with confirmation, sent / failed states (`POST /api/v1/emergency/trigger`), 1990 ambulance call, emergency contacts |
| Profile | Name, daily goals, appearance (System / Light / Dark, Reduce transparency), connected devices (coming soon), privacy and consent, sign out |

## Data

Supabase (row-level security, every query scoped to the signed-in user):

| Table | Used for |
|---|---|
| `profiles` | `full_name` |
| `water_logs`, `sleep_logs`, `mood_logs`, `meal_logs` | Tracking and history |
| `medications` | `name, dosage, times (HH:MM[]), start_date, end_date, source, status` (`confirmed` / `ended`) |
| `medication_logs` | `medication_id, taken_at` — one row per dose taken |
| `emergency_contacts` | `name, phone, relationship` |

Daily goals and appearance are stored on the device (`shared_preferences`).

## Structure

```
lib/
  main.dart                 Supabase init, theme mode from AppPrefs, AuthGate
  config.dart               values from dart_defines.json
  auth_gate.dart            login or app, by session
  app_shell.dart            tab bar, Scan button, loads Home data (with loading / error states)
  data/
    health_repository.dart  water, sleep, mood logging and Home snapshot
    care_repository.dart    medications, dose logs, history, emergency contacts, profile name
    care_models.dart        pure models + dose schedule logic (unit tested)
    app_prefs.dart          appearance and goals on the device
    scan_models.dart, sample_data.dart
  services/api_client.dart  backend calls (scan, chat, daily report, emergency) with mock mode
  screens/                  login, home, track (+ history), medications, scan, assistant,
                            daily report, emergency, profile
  widgets/                  glass, cards, buttons, rings, charts, states (loading / error / empty)
  theme/                    design tokens (colours, type, spacing, radius)
test/
  care_models_test.dart     schedule, parsing, active dates
  widget_test.dart          login validation, Track forms, appearance
assets/brand/logo.png       splash and brand mark
```
