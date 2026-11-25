# NOVA Health university demonstration

## Rehearsal checklist

- Prepare an approved disposable backend and Supabase project with migrations 001–016. Create synthetic accounts, confirm their login in advance, and load synthetic logs for both categories on at least one of the last seven completed local dates.
- Keep the demo backend in simulation mode with `NOTIFY_PROVIDER=log`. Use only synthetic emergency contacts. Rehearse the simulated SOS path without sending an SMS or placing a call.
- If demonstrating live scans, use the bundled fake prescription and lab images with an approved provider and the demo account's explicit consent. Set up an archived report ahead of time if demonstrating automatic generation. Keep a clearly labeled recording for hosted Cron, wearable imports, or notification delivery unless the actual devices and environment have been verified.
- Prepare a separate debug install with `USE_MOCK_API=true` for the offline fallback. It shows bundled synthetic prescription, lab, and food scan examples. Draft saves stay in memory. Chat, real accounts, scheduled reports, and native integration demos require a separate build and setup.
- Rehearse the selected sequence on the exact device or simulator and confirm backend health before presenting.

## Seven-minute walkthrough

1. **Account and profile (45 s).** Sign in to a synthetic account and show an account-specific tracking goal. Explain how RLS separates records.
2. **Tracking and medicines (60 s).** Save a tracking log, open its history, then mark and undo a scheduled synthetic dose. Verify that the displays refresh.
3. **Document review (75 s).** Open the original synthetic prescription photo and review the extracted fields and safety check. Show a reviewed synthetic lab record with its printed range, flag, or unknown value.
4. **Compare records (75 s).** Choose **Meals and hydration**, approve both sources, and show dated observations and attribution. The deterministic comparison stays within NOVA.
5. **Daily reports and alerts (55 s).** Show the saved automatic report and its time zone. Explain that medication reminders are scheduled locally, while report notices and weather planning notices are checked while NOVA is open.
6. **Emergency workflow (45 s).** Use the SOS simulation and show its status. Stop before opening a dialer or sending a real message.
7. **Close (30 s).** Report **466 backend and 175 Flutter regression tests** from final stabilization. Identify live-provider, hosted Cron, and signed-device checks separately. Describe NOVA as an evidence-grounded assistant with bounded comparisons.

If a live dependency fails, move to the offline scan build or a labeled recording. Describe which implementation is running before resuming the demonstration.
