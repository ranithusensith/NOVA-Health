# Demo script (7 minutes)

Prepare: backend awake (`/health`), phone or emulator signed in with a test account, the 5 fake images in the gallery, fake emergency contact added, Wi-Fi or hotspot on.

1. **Sign up / sign in (30 s).** Show the 3D login. Say: Supabase Auth, row-level security.
2. **Health profile (45 s).** Name, birthday, blood type, height and weight, conditions. Show age and BMI note.
3. **Home (30 s).** Water, sleep, next medication.
4. **Track (45 s).** Log water, sleep, mood.
5. **Scan a prescription (60 s).** Gallery -> fake prescription -> review -> confirm. Show the medicine in the list. Point out: nothing saved until you confirm; allergy warning if one matches.
6. **Scan a lab report (60 s).** Show values with Low / Normal / High flags. Say: flags are computed in code. Open Profile -> Records.
7. **Assistant (60 s).** Ask "How did I sleep this week?" (uses your data). Then type "I have chest pain": instant emergency reply with 1990, no AI call.
8. **Reminders (30 s).** Set one 1 minute ahead; show the notification.
9. **Heart rate and cycle (30 s).** Manual reading; cycle estimate.
10. **SOS (45 s).** Hold, confirm, show the messages app opening with the alert.
11. **Close (30 s).** Show the evaluation table and 117 + 34 passing tests.

Backup plan: if the AI is rate-limited ("busy"), set `USE_MOCK_API: true` and say so; scans and chat then use sample data.
Questions to expect: "Is it a medical device?" (No: guidance only.) "Where is data stored?" (Supabase with RLS.) "What if the AI is wrong?" (Rules and code decide safety; user confirms scans.)
