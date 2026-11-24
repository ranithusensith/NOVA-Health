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
- Run the upgrade during a maintenance window. The signup trigger installation and constraint validation acquire locks. Take a backup before applying changes to an existing project.

## Application database contract

| Area | Tables and access |
|---|---|
| Profile and onboarding | Flutter reads its profile and confirmed allergies and saves them through `save_health_profile`. Skipping onboarding updates only the name and onboarding flag. FastAPI reads profile context and confirmed allergies. |
| Medication and reminders | Flutter reads, adds, edits and stops `medications`, and logs or undoes `medication_logs`. FastAPI reads active medication for reports and safety checks and inserts reviewed prescriptions. The dose FK checks both medication ID and owner. |
| Tracking and reports | Flutter logs water, sleep, mood and meals. FastAPI reads these tables and `symptom_logs`. Time indexes support per-account history. |
| Wearables and cycle | Flutter reads, imports and deletes `wearable_samples` and manages `period_logs`. FastAPI reads summaries. The unique wearable key matches Flutter's duplicate-safe import. |
| Emergency | Flutter manages `emergency_contacts`. FastAPI reads contacts and inserts an SOS record into `audit_log`. |
| Lab results | Flutter saves, lists and removes `lab_results`. FastAPI reads summaries. |
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
  -f backend/changes/007_atomic_health_profile.sql

psql -X -v ON_ERROR_STOP=1 \
  -f backend/changes/tests/verify.sql \
  -f backend/changes/tests/patient_isolation.sql \
  -f backend/changes/tests/atomic_health_profile.sql
```

Start the test session as the disposable cluster administrator. The fixtures simulate the Auth schema, the Auth insert role, PostgREST roles and default API grants. They verify PostgreSQL access and integrity. Use separate loopback HTTP services or a disposable Supabase environment for token and HTTP integration.

To reproduce an upgrade when `002` through `004` have already run, start from the legacy fixture in a third disposable database. Apply those three files first, then apply `001` and `005`. Apply the H2 legacy fixture, apply `006` and `007`, and run all three verification files.

## H2 patient isolation and verification limits

Every application table has a restrictive owner policy. The owner key is `profiles.id` or `user_id` for the other tables. The dose log foreign key includes both owner and medication ID, and reviewed prescriptions are medication rows. FastAPI attaches the authenticated owner to its database reads and checks that inserts match that owner. Flutter filters reads and changes by account or supplies the owner in new rows. The wearable upsert conflict key includes the account ID.

The optional legacy chat table retains existing policies underneath the restrictive owner policy. Mobile and backend clients have no direct privileges on it. The cleanup RPC accepts no account argument and deletes rows matching the verified session subject. AI consent can be removed only for the caller's account. The signup trigger uses a pinned search path and its NOVA function remains unavailable to client roles.

- The PostgreSQL 16.14 suite tests grants, RLS, parent-child constraints, and account-scoped deletion for two synthetic accounts across fresh and legacy migrations. A separate loopback check used Supabase Auth 2.198.0 and PostgREST 16.6 to exercise signup, token refresh, rejection of missing, expired and invalid tokens, cross-account HTTP operations, and FastAPI consent and chat deletion. Hosted gateway configuration, deployed role mappings, and release app builds still need deployment-specific verification in a disposable environment.
- Use a publishable key or legacy anon key in Flutter. The app rejects a privileged key before initializing Supabase. A runtime guard cannot remove a value already compiled into a misconfigured mobile build. Inspect release inputs and artifacts before distribution, and keep privileged keys in server infrastructure.
- The database owner, superusers, and roles with `BYPASSRLS` can access patient data. Inventory custom roles, API-exposed views and functions, triggers, Storage policies, and Realtime publications on an isolated deployment copy. These deployment-specific objects are outside the repository migrations.
- Global uniqueness checks can reveal whether a known or guessable row ID exists through a conflict response. RLS protects the row contents. The SOS audit table accepts owner-scoped client inserts, so rows there do not independently prove a provider action.
- The signed-in database role can write its own medication rows directly. The reviewed-prescription safety and acknowledgement checks run on the FastAPI confirmation route and the supported Flutter workflow. The database owner policy does not attest to the origin or review of a patient's own medication row.
- `006` retains existing restrictive policies and grants needed by the app without expanding them. Validate expected owner workflows against the target deployment schema. Paths and effects of deployment-specific delete triggers or foreign keys depend on that schema.

## H3 health profile saves

`save_health_profile` uses the authenticated caller's grants and RLS policies. It checks the form's loaded account against `auth.uid()` and uses `auth.uid()` for all writes. It reconciles confirmed allergies by case-insensitive name, retains matching rows and their metadata, and updates the profile and onboarding flag after the allergy changes succeed. Repeating the same save preserves allergy IDs. The explicit skip path keeps previously saved health details and allergies.

The RPC serializes saves for the same profile. Conflicting forms still use the latest completed save because the app has no version check. Earlier app versions and direct API clients can still write authorized rows separately. During rollout, verify any custom grants and policies in a disposable copy, including whether the caller can read all of its confirmed allergy rows.
