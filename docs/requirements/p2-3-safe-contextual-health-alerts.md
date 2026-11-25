# P2-3 Safe context-aware health alerts

The September 23, 2026 NOVA Health proposal calls for context-aware notifications and weather-informed alerts. This implementation covers an opt-in outdoor planning notice based on a city the user chooses. It gives a reason to check local conditions and makes no individualized health-risk, diagnostic, emergency, or treatment claims.

## Eligible observations

NOVA accepts a live Open-Meteo forecast for the selected city's current calendar date, with a valid daily maximum precipitation probability of at least 60%. This is a product threshold for planning. The probability is a model estimate and can describe any hour in the forecast day. It does not establish current precipitation or the conditions at the user's location. [Open-Meteo forecast documentation](https://open-meteo.com/en/docs)

The forecast must belong to the selected city and remains usable only through the earlier of its freshness deadline, expiry, or city-local midnight. Missing probability is unknown. Stale forecasts, unavailable or demo data, and forecasts for other dates cannot trigger an alert. The settings screen shows the forecast's date and source, or a distinct unavailable, unknown, or stale state.

## Consent and delivery

- **Profile → Outdoor planning notices** starts off. Choosing a city alone does not enable notices. The user must approve checks for that city on that device. City searches are user-initiated. NOVA never requests device location for this feature.
- Signed-in, foreground checks use the existing weather service. NOVA verifies notification permission before contacting the provider and throttles checks to once every 30 minutes during a continuous session for the chosen city. The upstream provider receives the same public city lookup or coordinates as the Weather card. No health records, Gemini requests, or account identifiers go to the weather provider.
- A delivered notification uses the same generic lock-screen text as an automatic report notice. Its payload contains no city, timestamp, probability, account identifier, or health detail. Tapping it just opens NOVA through the operating system.
- NOVA records one claimed city date per account on this device. A duplicate check, restart, city change within the same date, or move to an earlier city date cannot send the same date again. A write or delivery failure can suppress a notice. The service checks again after the normal interval. Claims are device-local, so independent opt-ins on two devices can each deliver a notice.
- Opting out, changing the chosen city, or signing out invalidates in-flight checks and clears delivered outdoor notices. The app rechecks permission and current consent after restart. Device time-zone changes cannot shift the selected city's forecast window. Local preferences store the chosen city and latest claim date. Forecast details are held in memory.
- NOVA uses immediate foreground notices and creates no queued outdoor alarms or push deliveries. Conditions can change between checks. The feature does not replace official weather alerts or emergency services.

No database migration or Cron changes are required. This change does not use symptom, wearable, or medication records for alert decisions. Clinical alerts and other personalized contexts would need their own validated rules and consent.
