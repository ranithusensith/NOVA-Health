# NOVA Health

NOVA Health is a Flutter companion for recording and reviewing personal health information. The September 23, 2026 proposal describes an AGI-inspired research direction. The implementation uses a bounded, evidence-grounded assistant, deterministic comparisons, and explicit user consent.

## Implemented workflows

- **Account and tracking.** Supabase email/password authentication, a private health profile, and account-scoped records for water, sleep, mood, symptoms, medications, nutrition, and cycles.
- **Document and food review.** Prescription and lab photos go through private text extraction and review. A separate, consented food-image workflow offers editable estimates. Medication activation requires a safety check and explicit review.
- **Assistant and comparisons.** Gemini can select from approved tools after consent. NOVA renders record-backed facts and fixed safety guidance. On-demand comparisons pair sleep with steps, scheduled dose confirmations with symptom onsets, or meals with hydration.
- **Wearables and weather.** Apple HealthKit and Android Health Connect import supported step, sleep, and heart-rate data. Open-Meteo provides city forecasts. Opt-in outdoor notices use fresh forecasts while NOVA is open.
- **Reports and emergency assistance.** NOVA provides live reports and opt-in stored daily snapshots, scheduled medication reminders, and a user-confirmed SOS workflow with simulation and manual fallback options.

Automatic report generation requires a configured database job. Signed devices are needed to verify wearable imports and native delivery. Long-term analytics, background push, passive emergency detection, and broad clinical inference remain outside the implemented scope.

## Repository guide

- `mobile/` contains the Flutter Android and iOS application.
- `backend/` contains the FastAPI service, PostgreSQL migrations, and backend evaluation tools.
- `docs/` contains the architecture, privacy and safety controls, and proposal coverage notes.
- `test-data/` contains synthetic scan fixtures.

Start with the [university demonstration](docs/DEMO_SCRIPT.md), [deployment notes](DEPLOY.md), [database setup](docs/database-setup.md), and [evaluation](docs/EVALUATION.md).
