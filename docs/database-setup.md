# NOVA Health database setup

Flutter and FastAPI use Supabase Auth and the PostgREST API in the `public` schema. Configure both clients with the project URL and publishable key. FastAPI validates the bearer token through `/auth/v1/user` and forwards the same token to PostgREST. The signed-in request runs as `authenticated`, and RLS resolves its account through `auth.uid()`.

## Migration order

Start with a Supabase project that has Auth initialized. Use its SQL Editor or a trusted database migration connection. The migration role needs ownership of the NOVA tables and functions, permission to create objects in `public`, and the Supabase permissions to read, reference and install a trigger on `auth.users`. The migration role must be able to backfill `public.profiles` and run the legacy chat cleanup if `public.chat_messages` exists. Confirm these privileges and the Auth trigger on a disposable project before scheduling an existing-project rollout.

Run each file in order and stop on any SQL error. Apply the full sequence before pointing Flutter or FastAPI at a new database.

| Order | File | Purpose |
|---|---|---|
| 1 | [001_foundation.sql](../backend/changes/001_foundation.sql) | Create the foundational tables, indexes, foreign keys, signup trigger and RLS. Fill gaps for existing Auth users. |
| 2 | [002_lab_results.sql](../backend/changes/002_lab_results.sql) | Create the scanned lab results table, which references `profiles`. |
| 3 | [003_prescription_schedules.sql](../backend/changes/003_prescription_schedules.sql) | Add reviewed prescription plans and reminder preferences to `medications`. |
| 4 | [004_ai_privacy.sql](../backend/changes/004_ai_privacy.sql) | Add opt-in AI consent and the account-scoped legacy chat cleanup RPC. |
| 5 | [005_extension_access.sql](../backend/changes/005_extension_access.sql) | Harden grants and add a restrictive ownership policy for lab results and consent. |
| 6 | [006_patient_isolation.sql](../backend/changes/006_patient_isolation.sql) | Remove excess client grants, restrict legacy chat history to the cleanup RPC, and validate any missing lab, consent, and chat owner relationships. |
| 7 | [007_atomic_health_profile.sql](../backend/changes/007_atomic_health_profile.sql) | Save the caller's confirmed allergies, profile, and onboarding completion in one transaction. |
| 8 | [008_medication_dose_occurrences.sql](../backend/changes/008_medication_dose_occurrences.sql) | Store scheduled dose times and enforce one log per identifiable occurrence. |
| 9 | [009_lab_result_fidelity.sql](../backend/changes/009_lab_result_fidelity.sql) | Preserve reviewed lab result text, printed references and flags, and unknown report dates. Enforce exact numeric projections for reviewed rows. |
| 10 | [010_legacy_chat_retention.sql](../backend/changes/010_legacy_chat_retention.sql) | Add owner-only expiration for legacy chats without expanding client privileges. |
| 11 | [011_medication_safety_review.sql](../backend/changes/011_medication_safety_review.sql) | Gate medication activation and edits on an account-bound safety review. |
| 12 | [012_daily_tracking_goals.sql](../backend/changes/012_daily_tracking_goals.sql) | Store optional water and sleep tracking goals on the account profile. |
| 13 | [013_symptom_tracking.sql](../backend/changes/013_symptom_tracking.sql) | Add symptom notes, record revisions, validation and owner-scoped writes. |

Supabase Auth owns account identities. A signup creates a profile with the account UUID, the optional display name, empty conditions and goals, and onboarding marked incomplete. Health details remain unset until the user enters them. Existing profile fields retain their saved values. AI processing consent still requires its own explicit opt-in.

## Existing projects

Check the migration history and review a schema-only snapshot against these files in an isolated database. Apply `001` first if the baseline is missing, apply only the pending files from `002` through `004`, and then apply `005`. If `002` through `004` are already applied, the H1 files are `001` and `005`. Apply `006` after H1. Review the actual grants, policies, triggers, constraints and column types before choosing that path.

- `001` adds missing profile fields and the dose status field. It uses existing tables as-is for the remaining application columns. Verify those columns, types, defaults and keys against the migration before applying it.
- The migration keeps existing RLS policies and intersects them with the account boundary. Verify that existing grants and policies still allow the intended own-account operations. It adds the new app policies where RLS was previously disabled.
- The new signup trigger sorts after the conventional `on_auth_user_created` trigger and ignores an existing profile with the same ID. Review any custom Auth triggers for ordering and required profile values. Run a test signup on the copy.
- Foreign key validation and the wearable import index check the existing data. An orphaned reference, mismatched dose owner or duplicate wearable import key can abort `001` and roll back its changes. Resolve any conflicts against the source records before scheduling the migration.
- `006` also rolls back if an existing lab result, consent record, or chat has an orphaned owner where a new foreign key is needed. Review any old client integrations with `chat_messages` before an upgrade. Current Flutter and FastAPI use the cleanup RPC as their only access to that table.
- On legacy dose logs, `006` removes an immediate medication-ID-only foreign key with the default `NO ACTION` behavior when the validated owner-aware cascade is present. That redundant constraint could block a legacy account deletion before the cascade ran.
- Apply `007` before rolling out the Flutter client that calls `save_health_profile`. Earlier clients keep their existing direct-write behavior until upgraded.
- Apply `008` after `007` and before updating Flutter or FastAPI reports. It adds a stored generated column and indexes on `medication_logs`, which can rewrite and lock that table. Verify the schema change and PostgREST schema cache on a disposable copy. Existing dose logs stay in place.
- Apply `009` after `008` and before updating FastAPI or Flutter. Verify PostgREST can see the new columns in a disposable copy. Existing lab rows retain their values and dates.
- Apply `010` after `009`. Review the legacy chat schema on an isolated copy and follow the retention runbook before enabling the job.
- Apply `011` after `010`. Coordinate the migration, key provisioning and API/mobile releases as described under [P0-3 medication safety review](#p0-3-medication-safety-review).
- Apply `012` after `011` and before releasing the P0-4 Flutter app and API. Verify the new profile columns through PostgREST and check owner access on a disposable copy.
- Apply `013` after `012` and before using symptom tracking in Flutter or running the matching FastAPI version. Existing symptom entries remain readable. Verify the PostgREST schema cache and grants in an isolated deployment copy.
- Run the upgrade during a maintenance window. The signup trigger installation and constraint validation acquire locks. Take a backup before applying changes to an existing project.

## Application database contract

| Area | Tables and access |
|---|---|
| Profile and onboarding | Flutter reads its profile and confirmed allergies and saves them through `save_health_profile`. Skipping onboarding updates only the name and onboarding flag. FastAPI reads profile context and confirmed allergies. |
| Medication and reminders | Flutter reads and stops `medications` through Supabase and submits manual additions, edits and scan confirmations through FastAPI. It logs and undoes selected occurrences in `medication_logs`. FastAPI reviews final drafts and invokes the signed medication writer. The dose FK checks both medication ID and owner. |
| Tracking and reports | Flutter logs water, sleep, mood, meals and symptoms. Owners can edit, resolve and delete their symptom logs. FastAPI reads these tables for local reports and selected assistant evidence. Time indexes support per-account history. |
| Wearables and cycle | Flutter reads, imports and deletes `wearable_samples` and manages `period_logs`. FastAPI reads summaries. The unique wearable key matches Flutter's duplicate-safe import. |
| Emergency | Flutter manages `emergency_contacts`. FastAPI reads contacts and inserts an SOS record into `audit_log`. |
| Lab results | Flutter submits reviewed observations to FastAPI, which inserts the batch using the signed-in account's token. Flutter lists and removes its own records. Daily reports and assistant summaries read the corrected observations. |
| AI privacy | FastAPI reads and updates account-scoped `ai_processing_consents` and invokes `delete_legacy_ai_chats()`. The fresh schema has no chat history table. |

## Isolated SQL verification

Use a fresh, disposable PostgreSQL 16 cluster with a private Unix socket and TCP disabled. From the repository root, repeat the commands for two empty databases in that cluster. Set `PGHOST` to the temporary socket and `PGDATABASE` to the disposable database before running the commands. Run the legacy fixture for the second database.

```sh
psql -X -v ON_ERROR_STOP=1 -f backend/changes/tests/auth_fixture.sql

# Run this line only for the synthetic legacy database.
psql -X -v ON_ERROR_STOP=1 -f backend/changes/tests/legacy_fixture.sql

PGOPTIONS='-c role=h1_migration_owner' psql -X -v ON_ERROR_STOP=1 \
  -f backend/changes/001_foundation.sql \
  -f backend/changes/002_lab_results.sql \
  -f backend/changes/003_prescription_schedules.sql \
  -f backend/changes/004_ai_privacy.sql \
  -f backend/changes/005_extension_access.sql

# Run this line only for the synthetic legacy database.
psql -X -v ON_ERROR_STOP=1 -f backend/changes/tests/patient_isolation_legacy_fixture.sql

PGOPTIONS='-c role=h1_migration_owner' psql -X -v ON_ERROR_STOP=1 \
  -f backend/changes/006_patient_isolation.sql \
  -f backend/changes/007_atomic_health_profile.sql \
  -f backend/changes/008_medication_dose_occurrences.sql

psql -X -v ON_ERROR_STOP=1 -v h6_before_migration=1 -f backend/changes/tests/lab_result_fidelity.sql
PGOPTIONS='-c role=h1_migration_owner' psql -X -v ON_ERROR_STOP=1 \
  -f backend/changes/009_lab_result_fidelity.sql \
  -f backend/changes/010_legacy_chat_retention.sql

psql -X -v ON_ERROR_STOP=1 \
  -f backend/changes/tests/verify.sql \
  -f backend/changes/tests/patient_isolation.sql \
  -f backend/changes/tests/atomic_health_profile.sql \
  -f backend/changes/tests/medication_dose_occurrences.sql \
  -f backend/changes/tests/lab_result_fidelity.sql \
  -f backend/changes/tests/legacy_chat_retention.sql

# Test pgcrypto in a schema separate from the public API.
psql -X -v ON_ERROR_STOP=1 -c '
  create schema extensions;
  create extension pgcrypto with schema extensions;
  grant usage on schema extensions to h1_migration_owner;
'

PGOPTIONS='-c role=h1_migration_owner' psql -X -v ON_ERROR_STOP=1 \
  -f backend/changes/011_medication_safety_review.sql \
  -f backend/changes/012_daily_tracking_goals.sql

# Establish a synthetic symptom entry from the read-only baseline.
psql -X -v ON_ERROR_STOP=1 -v p11_before_migration=1 \
  -f backend/changes/tests/symptom_tracking.sql

PGOPTIONS='-c role=h1_migration_owner' psql -X -v ON_ERROR_STOP=1 \
  -f backend/changes/013_symptom_tracking.sql

psql -X -v ON_ERROR_STOP=1 \
  -f backend/changes/tests/medication_safety_review.sql \
  -f backend/changes/tests/daily_tracking_goals.sql \
  -f backend/changes/tests/symptom_tracking.sql \
  -f backend/changes/tests/atomic_health_profile.sql \
  -f backend/changes/tests/medication_dose_occurrences.sql \
  -f backend/changes/tests/lab_result_fidelity.sql \
  -f backend/changes/tests/legacy_chat_retention.sql
```

Start the test session as the disposable cluster administrator. The fixtures simulate the Auth schema, the Auth insert role, PostgREST roles and default API grants. They verify PostgreSQL access and integrity. Use separate loopback HTTP services or a disposable Supabase environment for token and HTTP integration.

To reproduce an upgrade when `002` through `004` have already run, start from the legacy fixture in a third disposable database. Apply those three files first, then apply `001` and `005`. Apply the H2 legacy fixture and `006` through `008`. Use the same H6 fixture and `009` and `010` commands above, then run the same verification sequence through migration `013`.

## H2 patient isolation and verification limits

Every application table has a restrictive owner policy. The owner key is `profiles.id` or `user_id` for the other tables. The dose log foreign key includes both owner and medication ID, and reviewed prescriptions are medication rows. FastAPI attaches the authenticated owner to its database reads and checks that inserts match that owner. Flutter filters reads and changes by account or supplies the owner in new rows. The wearable upsert conflict key includes the account ID.

The optional legacy chat table retains existing policies underneath the restrictive owner policy. Mobile and backend clients have no direct privileges on it. The cleanup RPC accepts no account argument and deletes rows matching the verified session subject. AI consent can be removed only for the caller's account. The signup trigger uses a pinned search path and its NOVA function remains unavailable to client roles.

- The PostgreSQL 16.14 suite tests grants, RLS, parent-child constraints, and account-scoped deletion for two synthetic accounts across fresh and legacy migrations. A separate loopback check used Supabase Auth 2.198.0 and PostgREST 16.6 to exercise signup, token refresh, rejection of missing, expired and invalid tokens, cross-account HTTP operations, and FastAPI consent and chat deletion. Hosted gateway configuration, deployed role mappings, and release app builds still need deployment-specific verification in a disposable environment.
- Use a publishable key or legacy anon key in Flutter. The app rejects a privileged key before initializing Supabase. A runtime guard cannot remove a value already compiled into a misconfigured mobile build. Inspect release inputs and artifacts before distribution, and keep privileged keys in server infrastructure.
- The database owner, superusers, and roles with `BYPASSRLS` can access patient data. Inventory custom roles, API-exposed views and functions, triggers, Storage policies, and Realtime publications on an isolated deployment copy. These deployment-specific objects are outside the repository migrations.
- Global uniqueness checks can reveal whether a known or guessable row ID exists through a conflict response. RLS protects the row contents. The SOS audit table accepts owner-scoped client inserts, so rows there do not independently prove a provider action.
- Migration `011` removes direct medication creation and editing grants from app roles. It retains owner-scoped reads and permits an active row to transition to ended for the existing Stop action.
- `006` retains existing restrictive policies and grants needed by the app without expanding them. Validate expected owner workflows against the target deployment schema. Paths and effects of deployment-specific delete triggers or foreign keys depend on that schema.

## H3 health profile saves

`save_health_profile` uses the authenticated caller's grants and RLS policies. It checks the form's loaded account against `auth.uid()` and uses `auth.uid()` for all writes. It reconciles confirmed allergies by case-insensitive name, retains matching rows and their metadata, and updates the profile and onboarding flag after the allergy changes succeed. Repeating the same save preserves allergy IDs. The explicit skip path keeps previously saved health details and allergies.

The RPC serializes saves for the same profile. Conflicting forms still use the latest completed save because the app has no version check. Earlier app versions and direct API clients can still write authorized rows separately. During rollout, verify any custom grants and policies in a disposable copy, including whether the caller can read all of its confirmed allergy rows.

## H4 medication dose logs

A daily dose is identified by its medication and local calendar date and clock time. An exact-interval dose is identified by its medication and UTC instant. Both store the selected instant in `scheduled_at`. Daily doses also store `scheduled_local_at` so a time-zone change on the same local date does not turn an already logged dose into a new occurrence. `taken_at` records when the log was written. The owner and medication foreign key and existing RLS still apply.

Logging ignores a duplicate occurrence and preserves the original row. Undo identifies the account, medication, occurrence and log row, so re-logging a dose creates a new row that an old Undo action cannot remove. There is no undo tombstone. A log request arriving after a successful Undo can re-create that occurrence.

Earlier app versions can still write timestamp-only logs. Because those logs cannot identify a scheduled dose, the current app leaves them unassigned and shows affected unconfirmed slots as unverified for that day. As-needed and unscheduled medications stay outside the scheduled-dose timeline. The app derives interval history dates from the device time zone, while FastAPI reports use its configured time zone. Changes to a medication's schedule can leave historical occurrences without a matching current slot.

## H6 reviewed lab results

`POST /api/v1/scan/report/confirm` validates the reviewed rows, checks ownership against the signed-in account and inserts them in a single batch. Reviewed result text is authoritative. Numeric `value` is populated only for an exact decimal. The printed range and flag are stored as text, and the original extracted result is retained separately when available. A missing report date stays `NULL`. Daily reports use only results with the selected report date. Medical records include undated results, and the assistant can read them when lab results are selected for that reply. The existing assistant redaction still applies to all outbound values.

The database retains existing owner-scoped permissions and direct writes for older clients. The H6 constraint applies to `scan_reviewed` rows. Earlier client saves may contain inferred flags or fallback dates. Migration `009` leaves those records as stored because the original printed information may be unavailable.

## H11 legacy chat retention

The signed-in account can use `delete_legacy_ai_chats()` to remove all of its own legacy chat rows immediately. The RPC accepts no owner argument. Other accounts' rows and separate consent records are unaffected. Legacy rows remain unavailable for direct client reads or writes.

Migration `010` installs the maintenance function without deleting any rows or scheduling a job. On a disposable copy, verify that the migration and legacy chat table have the expected owner, that delete triggers and foreign keys behave as intended, and that `created_at` is populated when that column exists. Timestamp values without a time zone are interpreted as UTC. A null timestamp or a missing `created_at` column means the row has no verifiable age and the job deletes it. An unsupported column type raises an error and requires schema review.

After the retention policy is approved, run the following SQL daily from a trusted maintenance job that connects as the database migration owner and has authority over the legacy table. The function removes rows at least 720 hours old when the job runs and returns only a count. A fresh installation returns zero. Record success, count and timing, and alert on job failures without capturing query data or raw exception detail. Rows remain eligible until a delayed job next runs.

```sql
select public.prune_legacy_ai_chats();
```

Keep the function unavailable to API roles and manage maintenance credentials outside the app. Backup and provider retention have separate controls. [External AI privacy policy](ai-privacy.md)


## P0-3 medication safety review

Manual additions, manual edits and scan confirmation use the same local rules. FastAPI checks the submitted final draft against confirmed allergies, conditions and currently active medicines. An edit substitutes the final draft for the prior row. The app displays warnings and requires an explicit acknowledgement before it can save that draft. The acknowledgement is bound to the account, draft, row revision and current warnings. FastAPI checks again on acknowledgement. A failed or unavailable check blocks activation. Checks and acknowledgements require no external AI processing or consent.

Medication changes use a short-lived, server-signed assertion. The writer checks the assertion against the caller's Supabase subject and checks the target's current revision on edits. Changes to conditions, allergies or medications invalidate an in-flight review for that account. Client roles retain existing owner-scoped read and dose-log access. The signed writer validates ownership explicitly under its database owner privileges. Review deployment-specific views, grants, functions, triggers and extra RLS policies on a disposable copy. Direct adds, edits and reactivation from older Flutter versions fail after this migration. Existing medication records retain their state and histories.

For a future approved rollout, install `pgcrypto` if needed and give the migration owner usage on its schema. Apply `011`. Provision 32 cryptographically random bytes through the protected database administration connection and put the same value, encoded as 64 hex characters, in the backend secret `MEDICATION_REVIEW_SIGNING_KEY` on all instances. Insert the decoded bytes in `public.nova_medication_signing_key.signing_key` with `singleton = true`. Use a bound parameter and exclude the operation and secret from logs, shell history and application builds. A missing key or a mismatched key blocks activation. Coordinate both sides of a rotation. Verify signed manual and scan saves, stopping and account isolation on a disposable copy before bringing up the matching app and API versions. Check the PostgREST schema cache after applying the migration.

The rule set covers a limited set of recognized allergy conflicts, condition cautions, duplicate ingredients and some dose calculations. It uses the current account data at review time. Existing rows are grandfathered until edited. Custom privileged database writers remain trusted.


## P0-4 daily tracking

- The device calendar defines the date. Timestamped rows belong to the interval from the selected local midnight up to, and excluding, the following midnight. The app sends the two applicable offsets to reports and sends the applicable calendar boundaries to NOVA's assistant when selected tracking or heart records need them. The assistant provider receives no offsets or calendar metadata. Earlier API clients use the configured server offset. Browsing an older day after travel uses the device's current time zone for that date.
- Sleep entries represent the entire night and are assigned to the local day they were logged. The latest entry replaces previous totals for that day. Distinct values at the same latest instant stay unknown. NOVA does not infer sleep sessions or combine naps from the saved duration records. Mood also uses the latest entry.
- Water adds recorded millilitres. A nutrition total adds calorie estimates from confirmed meals only, and stays unknown if any confirmed meal has an unavailable estimate. An empty log or an unavailable measurement stays unknown. Weekly numbers average days with available measurements. The assistant withholds claims based on incomplete or conflicting evidence.
- Goals belong to the authenticated profile and remain optional. Previously stored device goals must be entered again in Profile if users want them synced. Historical views show the current saved goals. A water target may represent a fluid cap, so NOVA displays it without prescribing a volume or scoring hydration. Follow any fluid instructions from the care team.
- The Flutter tracking score averages available sleep goal progress and the fraction of scheduled doses marked taken where at least one identifiable dose exists and no logs are unassigned. It is unavailable without comparable data. The score measures tracking progress. Mood, hydration and nutrition are displayed separately. It does not grade health or confirm that a dose was taken.


## P1-1 symptom tracking

Track → Symptoms lists the signed-in patient's entries newest first, including resolved entries. Each new log records a symptom type, onset and active or resolved status. Severity and notes are optional. An unsupported status or severity on an older record appears as unknown. Editing an older entry may require selecting a valid status or providing an onset before it can be saved. Resolution records the current status. The app does not infer a resolution date. History and edits use the account owner, and edits and deletes compare the loaded revision with the current row.

Migration `013` keeps the restrictive owner policy, existing reads and earlier records. It adds write access only to the authenticated owner. Future writes validate fields and use a fresh revision. The Flutter editor uses a stable ID for create retries. Direct owner writes are supported by RLS and validation. They bypass the Flutter draft warning screen, and saved entries can still be checked by NOVA on request.

Daily reports show symptoms with onset on the selected local date alongside the other recorded measurements. The assistant uses patient symptom entries when the user selects tracking logs for a reviewed reply and has external AI consent. NOVA writes the visible facts from those records. Symptom names, notes and onset dates stay out of the provider payload for selected symptom records. Local red-flag checks run independently of external AI consent.

The September 23, 2026 NOVA Health project proposal calls for symptom tracking in the deliverables and for symptoms to be connected with relevant health context in the core features. This workflow covers recording, reviewing and resolving observations, putting them alongside daily health data, and surfacing them in grounded assistant replies. P1-1 does not infer causes, attribute symptoms to other records, or add new clinical recommendations.
