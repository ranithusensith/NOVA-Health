# Safety design

Principle: **code decides what is safe; the AI only explains.**

| Risk | Control | Where |
|---|---|---|
| Emergency (chest pain, self-harm, stroke signs) | Fixed keyword and phrase rules run before any AI call; reply gives 1990 (ambulance) and 1926 (mental-health line) | `safety.py` |
| AI outage during an emergency | Emergency path needs no model call (tested 5/5) | `safety.py`, `agent.py` |
| Wrong medicine advice | Rule engine checks allergies, NSAID and paracetamol limits, conditions; results are warnings with sources | `rules.py` |
| Invented numbers | Daily report numbers come from code; the AI writes only the summary | `reports.py` |
| Wrong lab flags | Low / normal / high computed from the reported range in code | `scan.py` |
| Scan saved without review | Nothing is saved until the user confirms | app scan screens |
| Privacy | AI gets redacted text and a compact context; the backend uses the user's own token so row-level security applies; no secret key on the server | `db.py`, `schema.sql` |
| Diagnosis wording | Output guard blocks diagnosis and dose-change wording; every AI reply ends with "Guidance, not medical advice." | `safety.py` |
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

## Known gaps (future work)
- Location is not included in the SOS message (needs a location permission flow).
- Keyword rules cover English only; Sinhala and Tamil phrases are future work.
- No clinical validation; a clinician review of the rules is needed before real use.
