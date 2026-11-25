# P1-4 UI and nutrition

The NOVA Health project proposal dated September 23, 2026 lists prescription and medical-report scanning, food-image analysis, nutrition tracking, wearable integration and daily health reports among its deliverables. The comparison below covers the P1-4 changes within those deliverables.

| Proposal objective | P1-4 coverage |
| --- | --- |
| Turn prescriptions into structured records | Reviewers can zoom and pan the source photo while checking medicine fields. The preview uses the in-memory photo on the account's review screen. The preview adds no upload, export or write and leaves the existing confirmation and safety review in place. |
| Estimate and track nutrition from food images, with daily health reports | Users review and correct estimates before saving. Tracking history and daily reports display the confirmed quantities. Daily totals use only confirmed records on the selected local date, with an unknown total for a measurement if any meal is missing that measurement. Photo-derived values remain estimates. |
| Import step count, heart rate and sleep from supported wearables | The app identifies Apple Health and Health Connect as data sources. It does not verify individual devices or pair directly with them. |
| Provide a conversational health assistant | The assistant supports typed questions through the existing review and consent flow. The proposal does not specify dictation. The inactive Dictate control was removed because the app has no verified on-device speech workflow for sensitive health input. NOVA does not request microphone or speech-recognition permissions for assistant input. |

Meal quantities support whole kilocalories from 0 to 5,000, protein and fat from 0 to 500 grams, and carbs from 0 to 800 grams per meal. Gram fields accept one decimal place with a dot or comma. These are supported input ranges and precision, not dietary recommendations. Blank measurements are stored as unknown and a zero entry remains zero. Unsupported scan estimates are blank for review.

Apply [migration 015](../database-setup.md#migration-order) to enforce these rules on new database writes. Existing records are preserved. Invalid historical measurements appear as unknown in records and totals. Individual meal names stay in the signed-in Flutter views and are not sent as assistant evidence.
