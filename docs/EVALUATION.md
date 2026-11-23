# Evaluation

All data is fake. Model: `gemini-3.5-flash-lite` (real model), run on 2026-11-14 with `python -m eval.run_eval`.
Rule-based parts run offline and are deterministic.

## Method
- **Scans:** 2 fake prescriptions (3 medicines), 2 fake lab reports (12 values), 1 wrong-document image. Each result is compared with ground truth in `eval/cases.py`.
- **Metrics:** precision, recall, F1, field accuracy (dosage, frequency, duration, value, unit, range, flag), latency (median and p95), tokens.
- **Safety:** 25 emergency phrases, 25 normal questions (false alarms), 20 medicine-rule cases, 5 emergency messages that must never call the model.
- **Assistant:** 10 questions about the user's own data. Checks: the correct tool was used, the disclaimer is present, no forbidden wording.

## Results
| Component | Result |
|---|---|
| Prescription scan | 3/3 items, precision 1.00, recall 1.00, F1 1.00; dosage, frequency, duration 100% |
| Lab report scan | 12/12 values, F1 1.00; value, unit, range, flag 100% |
| Wrong-document rejection | 4/4 |
| Scan latency | prescription median 4.4 s (p95 6.4 s); lab report median 2.8 s |
| Assistant | correct tool 10/10; disclaimer 10/10; unsafe wording 0/10; errors 0; median about 2.7 s; 1 tool call per question |
| Emergency recognition | 25/25; false alarms 0/25 |
| Emergency bypass (no AI call) | 5/5 |
| Medicine rule engine | 20/20 |
| Automated tests | 117 backend tests passing; 34 app tests passing |

## Findings worth reporting
1. **Flags are computed in code**, so lab flags cannot be hallucinated. The model only reads text from the image.
2. **Emergency handling never depends on the AI.** Fixed rules answer first, so an AI outage cannot block it.
3. **Evaluation caught real bugs:** gaps in emergency keywords, a range-parsing bug (`-17.0`), and a false alarm on "What is stroke?".
4. **Rate limits are a real constraint.** Free tier: 20 requests per day per model. A first run showed lab recall 50%, which was a 429 rate-limit error (a failed call), not a model miss. The rerun scored 12/12. Production needs a paid tier or per-user quotas (implemented: 30 scans and 100 chats per user per day).
5. **Model availability changes.** `gemini-2.5-flash` returned 404 (retired for new users). The model name is a setting (`LLM_MODEL`), not code.
6. **Latency:** the reasoning-heavy models exceeded a 60 s timeout once; the timeout is now 180 s and a lite model is the default.

## Limitations (state these honestly)
- Small sample: 5 images, 10 assistant questions, 25 + 25 phrases. Results show the pipeline works, not clinical accuracy.
- Images are synthetic and clean. Real photos (blur, glare, handwriting) will score lower.
- One run per case (`--runs 1`), so there is no variance estimate. Use `--runs 3` to report mean and standard deviation.
- Cost was not computed (free tier). Run with `--price-in` and `--price-out` to estimate cost per scan.
- Not a medical device. Output is guidance, never a diagnosis.

## Reproduce
```
cd backend && source .venv/bin/activate
python -m pytest -q
python -m eval.run_eval --safety
python -m eval.run_eval --mock --all
python -m eval.run_eval --live-synthetic --scans
python -m eval.run_eval --live-synthetic --agent
```

Scan evaluation requires Tesseract and its English model. Mock mode runs local OCR and
blocks outbound HTTP. Set `--output-dir` to write reports outside the repository.
Scan and assistant evaluations use mock mode unless you select `--live-synthetic`.

Live mode is for the built-in synthetic cases and an approved staging evaluation
account. Export the approved provider and staging Supabase configuration explicitly
and supply the signed-in account's access token via `NOVA_EVAL_ACCESS_TOKEN`.
The account must have opted in to the current disclosure. The runner also asks
you to review and approve each extracted document before sending text to Gemini.
See [External AI privacy](ai-privacy.md).
