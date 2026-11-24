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

Supabase Auth owns account identities. A signup creates a profile with the account UUID, the optional display name, empty conditions and goals, and onboarding marked incomplete. Health details remain unset until the user enters them. Existing profile fields retain their saved values. AI processing consent still requires its own explicit opt-in.

## Existing projects

Check the migration history and review a schema-only snapshot against these files in an isolated database. Apply `001` first if the baseline is missing, apply only the pending files from `002` through `004`, and then apply `005`. If `002` through `004` are already applied, the H1 files are `001` and `005`. Review the actual grants, policies, triggers, constraints and column types before choosing that path.

- `001` adds missing profile fields and the dose status field. It uses existing tables as-is for the remaining application columns. Verify those columns, types, defaults and keys against the migration before applying it.
- The migration keeps existing RLS policies and intersects them with the account boundary. Verify that existing grants and policies still allow the intended own-account operations. It adds the new app policies where RLS was previously disabled.
- The new signup trigger sorts after the conventional `on_auth_user_created` trigger and ignores an existing profile with the same ID. Review any custom Auth triggers for ordering and required profile values. Run a test signup on the copy.
- Foreign key validation and the wearable import index check the existing data. An orphaned reference, mismatched dose owner or duplicate wearable import key can abort `001` and roll back its changes. Resolve any conflicts against the source records before scheduling the migration.
- Run the upgrade during a maintenance window. The signup trigger installation and constraint validation acquire locks. Take a backup before applying changes to an existing project.

## Application database contract

| Area | Tables and access |
|---|---|
| Profile and onboarding | Flutter reads and updates its `profiles` row and reads, adds and removes `allergies`. FastAPI reads profile context and confirmed allergies. |
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

psql -X -v ON_ERROR_STOP=1 -f backend/changes/tests/verify.sql
```

Start the test session as the disposable cluster administrator. The fixtures simulate the Auth schema, the Auth insert role, PostgREST roles and default API grants. They verify PostgreSQL access and integrity. Supabase Auth email confirmation and PostgREST HTTP and token integration require a separate disposable Supabase environment.

To reproduce an upgrade when `002` through `004` have already run, start from the legacy fixture in a third disposable database. Apply those three files first, then apply `001` and `005` and run `verify.sql`.
