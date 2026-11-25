# NOVA Health: API Contract

**Owner:** W.L.R. Sensith (review: Jayawardhana for backend, Kaluwitharana for AI engine)
**Status:** Draft v0.1 (Phase 1, Week 1)
**Style:** REST + JSON

---

## 1. Conventions

| Item | Rule |
|---|---|
| Base URL | `/api/v1` |
| Format | JSON (`Content-Type: application/json`) |
| Field names | `snake_case` |
| IDs | UUID strings |
| Timestamps | ISO 8601, UTC (`2026-10-04T08:30:00Z`) |
| Auth | `Authorization: Bearer <token>` on every endpoint except register and login |
| Image upload | `multipart/form-data` |
| Docs | FastAPI auto-docs at `/docs` |
| Versioning | Breaking changes go to `/api/v2` |

## 2. HTTP Methods

| Method | Use |
|---|---|
| `GET` | Read |
| `POST` | Create or trigger an action |
| `PATCH` | Partial update |
| `PUT` | Full replace |
| `DELETE` | Remove |

## 3. Status Codes

| Code | Meaning |
|---|---|
| 200 | OK |
| 201 | Created |
| 204 | Deleted, no content |
| 400 | Bad request |
| 401 | Not logged in or token expired |
| 403 | Not allowed to access this record |
| 404 | Not found |
| 405 | Request method is not supported for this route |
| 422 | Validation error |
| 429 | Too many requests |
| 500 | Server error |
| 502 | An upstream response was unreadable or the upstream service rejected an operation |
| 503 | A dependency is unavailable, misconfigured, or timed out |

## 4. Response Formats

### Success

```json
{ "data": { } }
```

### List (paginated)

Query: `?page=1&limit=20`

```json
{
  "data": [ ],
  "meta": { "page": 1, "limit": 20, "total": 57 }
}
```

### Error (same shape everywhere)

```json
{
  "error": {
    "code": "INVALID_INPUT",
    "message": "amount_ml must be positive"
  }
}
```

### Error codes

| Code | Used for |
|---|---|
| `INVALID_INPUT` | Failed validation |
| `UNAUTHORIZED` | Missing, invalid, or expired session token (401 with `WWW-Authenticate: Bearer`) |
| `FORBIDDEN` | Accessing another user's data |
| `NOT_FOUND` | Record does not exist |
| `METHOD_NOT_ALLOWED` | Unsupported HTTP method (405 with `Allow`) |
| `AUTH_UNAVAILABLE` | Session verification service is unavailable (503) |
| `AUTH_RESPONSE_INVALID` | Session verification returned an unreadable account response (502) |
| `SCAN_FAILED` | A usable document or meal could not be found in a valid scan response (422) |
| `OCR_UNAVAILABLE` | Local text extraction is unavailable (503) |
| `AI_UNAVAILABLE` | Model dependency outage or timeout (503) |
| `AI_PROVIDER_AUTH_FAILED` | The provider rejected NOVA's credentials or authorization (503) |
| `AI_REQUEST_REJECTED` | The provider rejected NOVA's request (502) |
| `AI_RESPONSE_INVALID` | The provider returned an unusable response (502) |
| `DATABASE_UNAVAILABLE` | Database dependency outage or timeout (503) |
| `DATABASE_RESPONSE_INVALID` | Unreadable database response (502) |
| `DATABASE_REQUEST_FAILED` | The database rejected an operation (502) |
| `RATE_LIMITED` | Too many requests |
| `SERVER_ERROR` | Unexpected failure inside NOVA (500) |

The error envelope contains a fixed code and a patient-safe message. Upstream response bodies and user-supplied field names are omitted. Error responses use `Cache-Control: no-store`. Consent and save endpoints retain their operation-specific errors. If the outcome of a write is unverified, check the relevant records before retrying it.

## 5. Endpoints (Draft)

### 5.1 Auth

| Method | Path | Purpose |
|---|---|---|
| POST | `/auth/register` | Create account |
| POST | `/auth/login` | Get access token |
| POST | `/auth/refresh` | Refresh token |
| POST | `/auth/logout` | Invalidate token |

### 5.2 Profile

| Method | Path | Purpose |
|---|---|---|
| GET | `/profile` | Get own profile |
| PATCH | `/profile` | Update profile |
| GET | `/emergency-contacts` | List contacts |
| POST | `/emergency-contacts` | Add contact |
| DELETE | `/emergency-contacts/{id}` | Remove contact |

### 5.3 Medications

| Method | Path | Purpose |
|---|---|---|
| GET | `/medications` | List medications |
| POST | `/medications` | Add medication |
| PATCH | `/medications/{id}` | Update medication |
| DELETE | `/medications/{id}` | Remove medication |
| POST | `/medications/{id}/log` | Log a dose taken |

### 5.4 Tracking

| Method | Path | Purpose |
|---|---|---|
| POST | `/tracking/water` | Log water intake |
| POST | `/tracking/sleep` | Log sleep |
| POST | `/tracking/mood` | Log mood |
| POST | `/tracking/symptoms` | Log symptom |
| POST | `/tracking/period` | Log cycle data |
| GET | `/tracking/{type}?from=&to=` | Get logs by date range |

### 5.5 Scanning

| Method | Path | Purpose |
|---|---|---|
| POST | `/scan/medical-text` | Extract text from a medical photo inside NOVA for user review |
| POST | `/scan/prescription` | Send reviewed clinical text for a prescription draft |
| POST | `/scan/report` | Send reviewed clinical text for a lab-result draft |
| POST | `/scan/food` | Send a reviewed food photo, re-encoded by NOVA, for a nutrition estimate |

### 5.6 Wearables

| Method | Path | Purpose |
|---|---|---|
| POST | `/wearables/sync` | Upload steps, heart rate, sleep from the phone |
| GET | `/wearables/summary?date=` | Get daily wearable summary |

### 5.7 Weather

| Method | Path | Purpose |
|---|---|---|
| GET | `/weather/cities?query=` | Search populated places by city and optional region or country |
| GET | `/weather/current?city_id=` | Read model conditions and a three-day forecast for a selected city |

Both endpoints require a signed-in session. City results include an ID, name, region and country. Current returns a `live`, `stale` or `unavailable` status. When values exist, it includes source and freshness timestamps, model conditions and a forecast by city date. Individual missing values are null. The Flutter demo uses a bundled sample independently of these endpoints.

A reviewed assistant request can carry `weather: {"city_id": 123, "consent": true}` when the user opts in for that reply. NOVA fetches the selected city's weather after the existing AI consent and emergency checks. It appends only live evidence and labels the source as `weather`. The city selection and weather observations are excluded from the Gemini payload.

### 5.8 AI Assistant and Reports

| Method | Path | Purpose |
|---|---|---|
| POST | `/assistant/chat` | Send a reviewed question to Gemini after opt-in |
| POST | `/assistant/comparison` | Compare two approved record categories on the NOVA backend |
| POST | `/symptoms/check` | Check an authenticated, unsaved symptom draft using NOVA’s local red-flag rules |
| GET | `/privacy/ai` | Read provider availability, disclosure version and current account consent |
| POST | `/privacy/ai` | Enable with the current disclosure version, or revoke consent |
| DELETE | `/privacy/ai/chats` | Delete the signed-in account’s legacy NOVA chat rows |
| GET | `/reports/daily?date=&start_offset_minutes=&end_offset_minutes=` | Get the NOVA report for the selected local calendar date |
| GET | `/insights?range=week` | Get long-term insights |

Supply both midnight UTC offsets when requesting a device-local date. The response marks the calendar basis as `device` or `configured`. When chat selects tracking logs or heart-rate records, the app can send `local_calendar` with the local `today` date and 31 ordered `midnight_offsets` from 29 days before today through tomorrow. These values are used only within NOVA.

The symptom check accepts `name`, optional `notes`, an offset-aware `started_at` and a `status` of `active` or `resolved`. It returns `emergency` and fixed `reply` text if current red flags match. The endpoint uses no provider and makes no database writes. Flutter manages symptom records through the owner-scoped Supabase table.

### 5.9 Notifications and Emergency

| Method | Path | Purpose |
|---|---|---|
| POST | `/notifications/device` | Register device push token |
| GET | `/notifications` | List notifications |
| POST | `/emergency/trigger` | Start emergency workflow |
| POST | `/emergency/cancel` | Cancel a false alarm |

## 6. Examples

### 6.1 Register

```
POST /api/v1/auth/register
```

Request:

```json
{
  "email": "user@example.com",
  "password": "********",
  "full_name": "Sample User"
}
```

Response `201`:

```json
{
  "data": {
    "id": "7c9e6679-7425-40de-944b-e07fc1f90ae7",
    "email": "user@example.com",
    "full_name": "Sample User"
  }
}
```

### 6.2 Login

```
POST /api/v1/auth/login
```

Request:

```json
{ "email": "user@example.com", "password": "********" }
```

Response `200`:

```json
{
  "data": {
    "access_token": "<jwt>",
    "refresh_token": "<jwt>",
    "expires_in": 3600
  }
}
```

### 6.3 Log water

```
POST /api/v1/tracking/water
```

Request:

```json
{ "amount_ml": 250, "logged_at": "2026-10-04T08:30:00Z" }
```

Response `201`:

```json
{
  "data": {
    "id": "b1f2c3d4-0000-4000-8000-000000000001",
    "amount_ml": 250,
    "logged_at": "2026-10-04T08:30:00Z"
  }
}
```

### 6.4 Add medication

```
POST /api/v1/medications
```

Request:

```json
{
  "name": "Sample Medicine",
  "dosage": "500 mg",
  "times": ["08:00", "20:00"],
  "start_date": "2026-10-04",
  "end_date": "2026-10-14"
}
```

Response `201`:

```json
{
  "data": {
    "id": "b1f2c3d4-0000-4000-8000-000000000002",
    "name": "Sample Medicine",
    "dosage": "500 mg",
    "times": ["08:00", "20:00"],
    "start_date": "2026-10-04",
    "end_date": "2026-10-14"
  }
}
```

### 6.5 Scan prescription

```
POST /api/v1/scan/prescription
Content-Type: application/json
```

Request: `{"text":"Sample medicine 500 mg twice daily","reviewed":true}`.
Prescription and lab report text may first be extracted with `POST /api/v1/scan/medical-text`
and multipart form field `image` (JPEG, PNG or WebP, max 8 MB). The OCR endpoint
does not call Gemini. Reviewed food uploads use multipart fields `image` and `reviewed=true`.
External AI requires current account consent and approved provider configuration.

Response `200`:

```json
{
  "data": {
    "scan_id": "b1f2c3d4-0000-4000-8000-000000000003",
    "medications": [
      {
        "name": "Sample Medicine",
        "dosage": "500 mg",
        "frequency": "twice daily",
        "duration_days": 10
      }
    ],
    "confidence": 0.86,
    "needs_user_confirmation": true
  }
}
```

Note: scan results must be confirmed by the user before being saved as medications.

### Lab report review

`POST /api/v1/scan/report` takes the same reviewed-text payload as prescription extraction. Its response includes `scan_id`, optional `report_type` and `report_date`, and draft `results`. Each draft includes `test`, `value_text`, `unit`, `reference_text` and `reported_flag`. A missing or unverified field is `null`. Keep comparison operators in `value_text`.

Send the selected and corrected rows to `POST /api/v1/scan/report/confirm` using the signed-in account's token.

```json
{
  "scan_id": "b1f2c3d4-0000-4000-8000-000000000003",
  "expected_user_id": "b1f2c3d4-0000-4000-8000-000000000001",
  "reviewed": true,
  "report_type": "Synthetic lab report",
  "report_date": null,
  "results": [
    {
      "test": "Sample analyte",
      "value_text": "<=0.40",
      "extracted_value_text": "<=0.50",
      "unit": "mg/L",
      "reference_text": "<0.30",
      "reported_flag": "H"
    }
  ]
}
```

Supply 1–60 results and a confirmed date in `YYYY-MM-DD` format or `null`. The server assigns ownership and derives any exact numeric values. Success returns `{"data":{"saved":1}}`. Confirmation stays within NOVA and does not call the AI provider. If a save returns `LAB_SAVE_UNVERIFIED`, check Medical records. Retrying the same scan ID does not create a duplicate batch.

### 6.6 Assistant chat

```
POST /api/v1/assistant/chat
```

Request:

```json
{
  "message": "Summarize my sleep logs.",
  "reviewed": true,
  "health_data": ["logs"],
  "recent_questions": []
}
```

Response `200`:

```json
{
  "data": {
    "reply": "Sleep logs (last 7 calendar days, including today), average per logged day: 5.5 hours.\n\nSaved records alone cannot establish a diagnosis or rule out a health problem. Ask a doctor or pharmacist about symptoms or treatment.\n\nGuidance, not medical advice.",
    "sources": ["sleep"],
    "warnings": [],
    "emergency": false
  }
}
```

Gemini can select read-only tools allowed for the reviewed turn. NOVA builds the visible reply from returned records and fixed safety rules. Model-written claims and model-supplied source labels are ignored. The `sources` array identifies the record categories that supplied displayed facts. It is empty when no source supplied a fact.

The assistant summarizes saved records with a bounded lookback. Averages are rounded and use logged days only. Missing or unreadable entries, multiple sleep entries on the same calendar day, conflicting heart-rate readings at the same instant, and differing lab entries for the same test and report date can prevent a numerical summary. Check Medical records for full lab values, units, ranges, flags, and rows omitted by the summary. Saved records may be incomplete, outdated, or entered incorrectly. The assistant does not diagnose, provide open-ended model advice, or verify the original clinical measurement. Clinical and live-provider validation of tool selection are still pending.

### 6.7 On-demand record comparison

`POST /api/v1/assistant/comparison` requires the caller's bearer token, `expected_account` (the signed-in UUID), `comparison`, `consented_sources`, and `local_calendar` (the device's local date and 31 midnight UTC offsets). The requested pair determines the only accepted source IDs.

| Comparison | Required source IDs |
| --- | --- |
| `sleep_steps` | `sleep`, `steps` |
| `medication_symptoms` | `scheduled_doses`, `symptoms` |
| `meals_water` | `meals`, `water` |

The response returns `data.reply`, `data.sources` for the evidence actually shown, and `data.emergency`. The endpoint rejects mismatched accounts, missing or extra sources, and unexpected fields before reading records. When both dose and symptom categories are approved, the existing acute symptom check runs first and can preempt the comparison. The endpoint accepts no free-text question or proposed answer, makes no provider calls, and returns `Cache-Control: no-store`.

### 6.8 Error example

```
POST /api/v1/tracking/water
{ "amount_ml": -5 }
```

Response `422`:

```json
{
  "error": {
    "code": "INVALID_INPUT",
    "message": "amount_ml must be positive"
  }
}
```

## 7. Rules for the Team

1. Do not change an endpoint without updating this file and telling the team.
2. Backend implements these paths exactly. Mobile builds against them.
3. Until the backend is ready, mobile uses mock responses that match the examples above.
4. Every endpoint (except register and login) checks the token and returns only the current user's data.
5. Never put real personal health data in examples, tests, or commits.
6. AI-generated output (scan results, assistant replies, reports) is guidance, not a medical diagnosis. The app must show a disclaimer.

## 8. Open Questions

1. Final database choice and ID format (owner: database design).
2. Does the AI engine run as a separate service or as a module inside the backend?
3. Rate limits for the AI endpoints.
4. Image storage: keep the original image or delete it after scanning?

## 9. Related Documents

- Architecture: `architecture.md`
