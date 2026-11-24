# Safety design

The assistant uses Gemini to select allowed tools. NOVA assembles replies from saved evidence and fixed safety rules.

| Risk | Control | Where |
|---|---|---|
| Emergency wording | Fixed English, Sinhala, and Tamil rules check current statements and common negation, conditional, historical, and quotation patterns before Gemini | `safety.py`, `main.py` |
| Backend or AI outage during an emergency | Gemini consent and availability are unnecessary for the backend preflight. Flutter offers a direct dialer action when preflight fails and does not forward the message for AI processing | `main.py`, `assistant_screen.dart` |
| Wrong medicine advice | Rule engine checks allergies, NSAID and paracetamol limits, conditions; results are warnings with sources | `rules.py` |
| Invented numbers | The backend renders assistant observations from account-scoped records. Report numbers and summaries are computed locally on the server | `assistant_evidence.py`, `reports.py` |
| Wrong lab flags | Reviewed printed flags and comparison operators are preserved. Unknown results stay unknown | `lab_results.py` |
| Scan saved without review | Nothing is saved until the user confirms | app scan screens |
| Privacy | AI gets redacted text and a compact context; the backend uses the user's own token so row-level security applies; no secret key on the server | `db.py`, [database setup](database-setup.md) |
| Diagnosis, treatment, and reassurance | Patient-facing assistant prose comes from fixed summaries. The output guard also blocks common unsafe wording in other displayed safety notes and reports | `agent.py`, `safety.py` |
| Abuse and cost | Daily quotas per user; image size and type checks | `main.py`, `scan.py` |
| SOS spam | 30-second cooldown; SOS is logged | `main.py` |
| SOS without internet | App opens the phone's messages app with the alert ready | `emergency_screen.dart` |

## SOS flow
1. User holds the SOS button for 3 seconds, then confirms.
2. App calls `POST /api/v1/emergency/trigger`.
3. Server reads the user's contacts (their own rows only), sends SMS (Twilio) or logs (default), and records an audit entry.
4. If the server could not send (no provider, or no internet), the app opens the messages app with every contact and the text filled in.
5. The screen always shows 1990 for a life-threatening emergency.

The SMS contains only the user's name and a request for help. No health data is sent.

## Assistant escalation and synthetic cases

An urgent match produces a fixed response and a user-initiated call button. When the preflight request times out or returns an invalid response, the app keeps the draft and offers the same action with an explicit message that NOVA could not check it. The button opens the device dialer when supported. The user places the call. The in-app number targets Sri Lanka, and the app directs users elsewhere to local emergency services.

For reviewed assistant requests that include logs, NOVA checks the caller's active symptom entries from the preceding 24 hours before Gemini consent or tool selection. Today's report runs the same check. The symptom editor checks a recent active draft locally within NOVA before saving. Alerts say the entry is marked active and its current state is unconfirmed. The saved-entry lookup is bounded to the 100 most recent matching rows and checks labels and notes for existing red-flag wording. Historical reports, resolved entries, and entries outside the window do not generate current alerts. Checks run on request. A patient can continue to save after reading the matching guidance or an unavailable-check notice. Calling for help requires the patient to open the dialer. Symptoms are not monitored in the background.

The synthetic evaluation includes emergency and non-emergency examples in English, Sinhala, and Tamil. Categories and the handling of recent stroke-like signs were informed by published guidance. The fixtures and translations have not been independently reviewed by a clinician or native-speaker reviewer. [NHS emergency guidance](https://www.nhs.uk/nhs-services/urgent-and-emergency-care-services/when-to-call-999/) · [NHS stroke symptoms](https://www.nhs.uk/conditions/stroke/symptoms/) · [Suwa Seriya ambulance service](https://www.1990.lk/news/1990-suwaseriya/) · [Sri Lanka National Institute of Mental Health](https://nimh.health.gov.lk/en/contact-us/)

## Known gaps (future work)
- Location is not included in the SOS message (needs a location permission flow).
- Phrase rules have limited coverage of paraphrases, dialects, and mixed-language context. A non-match cannot establish safety. The offline app provides a call action without evaluating the wording locally.
- Clinical review, native-language validation, and physical-device dialer testing are pending.
