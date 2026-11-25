# P2-1 Verified Cross-Domain Health Intelligence

The September 23, 2026 NOVA Health proposal describes an engine that connects medical, nutritional, behavioral, wearable, and environmental information. It identifies cross-domain reasoning and personalized assistance as objectives. P2-1 implements a bounded part of that objective by aligning and comparing verified observations across two approved categories at a time. It preserves the existing evidence-grounded chat and daily report paths.

## Observations and limits

| Pair | What is compared on each completed device-local date |
| --- | --- |
| Sleep and steps | Latest valid manual sleep duration and the imported step total for the exact day window. Competing latest sleep entries suppress the duration. Step snapshots captured before the end of the date, conflicting snapshots, and future captures are excluded. The platform name accompanies a step total. |
| Scheduled doses and symptoms | The number of distinct scheduled dose confirmations recorded that day and the number of symptom entries with onset that day. Dose confirmations omit PRN and older unassigned logs. Counts cannot establish adherence, missed doses, symptom progression, or medication effects. The existing recent active symptom check can preempt the comparison. |
| Meals and hydration | Confirmed meal count, meal calorie estimate if every confirmed meal has a usable calorie value, and the saved volume of water. A logged volume cannot establish hydration status or a safe water target. |

The comparison counts only dates on which both categories have verified observations and labels any single-source observation separately. It looks back seven completed local dates and keeps missing values unknown. An incomplete calorie total can be unknown while the confirmed meal count is available. Daily calculation rules for manual sleep, water, and confirmed calories are shared with the daily report. A saved observation is verified here when it comes from the authenticated, owner-filtered record query and passes the local checks. This does not validate the underlying clinical measurement, the user's record-keeping, or completeness of a provider's sync.

The reply is assembled from fixed templates, validated values, source labels, and local dates. Shared dates do not support a clinical relationship or causation. The comparison makes no diagnoses, treatment recommendations, or risk predictions. It doesn't analyze arbitrary pairings, label trends, subscribe to updates, or send proactive alerts. Weather remains an independently consented source in the existing chat path.

## Synthetic evaluation

- Sleep and steps match on a 23-hour day and across UTC midnight. Current-day, mismatched-window, premature, future-dated, and conflicting step observations do not become whole-day totals.
- Matching latest-time sleep entries that disagree are withheld. Disjoint dates, missing data, and unavailable queries cannot produce a paired claim. A genuine step total of zero is retained.
- Confirmed meals can contribute a verified count with unknown calories. Water summaries contain no hydration recommendations. Scheduled confirmations are deduplicated and historical or resolved symptoms do not preempt the comparison.
- Each request requires both categories and the correct account. Synthetic HTTP tests check scoped database filters and verify that only the selected tables are queried. Extra answer text is rejected, and neither model output nor private record notes can enter a comparison.
- Flutter tests cover separate approvals, resetting permissions when the pair changes, source attribution, and discarding a late reply after a conversation reset.

The feature needs matching Flutter and API versions and uses existing database migrations through 015. No new schema or provider configuration is required.
