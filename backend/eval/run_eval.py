"""
NOVA Health evaluation. Run from backend/:

  python -m eval.run_eval --mock                     # synthetic fixtures, no network
  python -m eval.run_eval --safety                   # offline emergency and medicine rules
  python -m eval.run_eval --live-synthetic --scans   # approved, consented evaluation account only

Use only synthetic inputs. Report files default to eval/results/.
"""

import argparse
import asyncio
import json
import os
import random
import sys
import time
from contextlib import ExitStack
from datetime import datetime
from functools import partial
from pathlib import Path
from unittest.mock import patch

import httpx

HERE = Path(__file__).resolve().parent
BACKEND = HERE.parent
sys.path.insert(0, str(BACKEND))
sys.path.insert(0, str(BACKEND / "tests"))

import agent  # noqa: E402
import ai_privacy  # noqa: E402
import llm  # noqa: E402
import rules  # noqa: E402
import safety  # noqa: E402
import scan  # noqa: E402
from eval import cases, metrics  # noqa: E402
from fakes import FakeDB  # noqa: E402

SYNTHETIC_IMAGE_DIR = BACKEND.parent / "test-data"
CLINICAL_TEXT_SEPARATOR = "\nClinical text (JSON string):\n"


# ============================================================== mock model (checks the script, not the AI)
class MockModel:
    """Answers from the ground truth. noise > 0 corrupts a share of fields so the metrics drop."""

    def __init__(self, documents: dict[str, str], noise: float, seed: int = 1):
        self.by_text = {text: name for name, text in documents.items()}
        if len(self.by_text) != len(documents):
            raise ValueError("Evaluation documents must have distinct reviewed text.")
        self.noise = noise
        self.rng = random.Random(seed)

    def _maybe(self, good, bad):
        return bad if self.rng.random() < self.noise else good

    async def __call__(self, prompt, *, authorize, system=None):
        await authorize()
        llm.USAGE.append({"in": 1200, "out": 150})
        prompt, separator, encoded_text = prompt.partition(CLINICAL_TEXT_SEPARATOR)
        reviewed_text = json.loads(encoded_text) if separator else None
        name = self.by_text[reviewed_text] if separator else None
        if prompt == scan.PRESCRIPTION_PROMPT:
            exp = cases.PRESCRIPTIONS.get(name)
            if not exp:
                return {"is_prescription": False, "medications": [], "confidence": 0.3}
            meds = [{
                "name": e["name"],
                "dosage": self._maybe(e["dosage"], "250 mg"),
                "frequency": self._maybe(f"{e['times_per_day']} times a day", "once a day"),
                "duration_days": self._maybe(e["duration_days"], 14),
            } for e in exp]
            return {"is_prescription": True, "medications": meds, "confidence": 0.9}
        if prompt == scan.REPORT_PROMPT:
            exp = cases.REPORTS.get(name)
            if not exp:
                return {"is_report": False, "results": [], "confidence": 0.3}
            rows = []
            for e in exp:
                line = next((line for line in reviewed_text.splitlines() if line.startswith(e["test"] + " ")), None)
                rows.append({
                    "source_line": line, "test": e["test"],
                    "value_text": self._maybe(e["value_text"], "999"), "unit": e["unit"],
                    "reference_text": e["reference_text"],
                })
            return {"is_report": True, "results": rows, "confidence": 0.9}
        if "USER QUESTION\n" in prompt:
            q = prompt.split("USER QUESTION\n", 1)[1].split("\n", 1)[0]
            case = next((c for c in cases.AGENT_CASES if c["q"] == q), None)
            if case and "TOOL RESULTS" not in prompt:
                args = {"kind": case["kind"], "days": 7} if "kind" in case else {}
                return {"action": "tool", "tool": case["tool"], "args": args}
            return {"action": "final", "answer": "Here is a short summary of your data.", "used": []}
        return {}


# ============================================================== helpers
async def prepare_documents(folder: Path, *, live: bool) -> dict[str, str]:
    names = set(cases.PRESCRIPTIONS) | set(cases.REPORTS) | {name for name, _ in cases.REJECTIONS}
    documents = {}
    for name in sorted(names):
        original = (folder / name).read_bytes()
        text = safety.clinical_text(await ai_privacy.extract_medical_text(original))
        if not any(character.isalpha() for character in text):
            raise ValueError(f"No usable reviewed text for {name}.")
        if live:
            print(f"Review synthetic clinical text for {name}:\n{text}\n")
            if input("Type share to approve this exact text for Gemini: ").strip() != "share":
                raise ValueError("Evaluation stopped before sending unapproved text.")
        documents[name] = text
    return documents


def cost(price_in, price_out, usage_slice):
    tin = sum(u["in"] for u in usage_slice)
    tout = sum(u["out"] for u in usage_slice)
    if price_in is None or price_out is None:
        return tin, tout, None
    return tin, tout, tin / 1e6 * price_in + tout / 1e6 * price_out


def pct(x, n):
    return f"{100 * x / n:.0f}%" if n else "n/a"


# ============================================================== scan evaluation
async def eval_scans(documents, runs, price_in, price_out, *, authorize):
    rows = []  # one dict per task result
    for run in range(runs):
        for name, expected in cases.PRESCRIPTIONS.items():
            u0, t0 = len(llm.USAGE), time.perf_counter()
            try:
                res = await scan.scan_prescription(documents[name], authorize=authorize)
                got = [m.model_dump() for m in res.medications]
                score, ok = metrics.score_prescription(expected, got), True
            except (scan.ScanError, llm.LLMError) as e:
                score, ok, got = {"tp": 0, "fn": len(expected), "fp": 0, "pairs": 0, "dosage": 0, "frequency": 0, "duration": 0}, False, str(e)
            rows.append({"task": "prescription", "file": name, "run": run, "ok": ok, "score": score,
                         "seconds": time.perf_counter() - t0, "usage": llm.USAGE[u0:]})
        for name, expected in cases.REPORTS.items():
            u0, t0 = len(llm.USAGE), time.perf_counter()
            try:
                res = await scan.scan_report(documents[name], authorize=authorize)
                got = [r.model_dump() for r in res.results]
                score, ok = metrics.score_report(expected, got), True
            except (scan.ScanError, llm.LLMError):
                score, ok = {"tp": 0, "fn": len(expected), "fp": 0, "pairs": 0, "value": 0, "unit": 0, "range": 0, "flag": 0}, False
            rows.append({"task": "report", "file": name, "run": run, "ok": ok, "score": score,
                         "seconds": time.perf_counter() - t0, "usage": llm.USAGE[u0:]})
        for name, endpoint in cases.REJECTIONS:
            u0, t0 = len(llm.USAGE), time.perf_counter()
            rejected = False
            try:
                fn = scan.scan_prescription if endpoint == "prescription" else scan.scan_report
                await fn(documents[name], authorize=authorize)
            except scan.ScanError:
                rejected = True
            except llm.LLMError:
                continue
            rows.append({"task": "rejection", "file": f"{name} -> {endpoint}", "run": run, "ok": rejected, "score": {},
                         "seconds": time.perf_counter() - t0, "usage": llm.USAGE[u0:]})

    out = {"rows": rows, "summary": {}}
    for task, fields in (("prescription", ["dosage", "frequency", "duration"]), ("report", ["value", "unit", "range", "flag"])):
        sel = [r for r in rows if r["task"] == task]
        if not sel:
            continue
        tot = {}
        for r in sel:
            tot = metrics.add_scores(tot, r["score"])
        p, rc, f1 = metrics.prf(tot.get("tp", 0), tot.get("fn", 0), tot.get("fp", 0))
        per_run_f1 = []
        for run in range(runs):
            t = {}
            for r in [x for x in sel if x["run"] == run]:
                t = metrics.add_scores(t, r["score"])
            per_run_f1.append(metrics.prf(t.get("tp", 0), t.get("fn", 0), t.get("fp", 0))[2])
        m, sd = metrics.mean_sd(per_run_f1)
        out["summary"][task] = {
            "items_found": f"{tot.get('tp', 0)}/{tot.get('tp', 0) + tot.get('fn', 0)}",
            "precision": p, "recall": rc, "f1": f1, "f1_mean": m, "f1_sd": sd,
            "fields": {f: pct(tot.get(f, 0), tot.get("pairs", 0)) for f in fields},
            "p50_s": metrics.percentile([r["seconds"] for r in sel], 0.5),
            "p95_s": metrics.percentile([r["seconds"] for r in sel], 0.95),
            "calls": len(sel),
        }
    rej = [r for r in rows if r["task"] == "rejection"]
    if rej:
        out["summary"]["rejection"] = {"correct": f"{sum(r['ok'] for r in rej)}/{len(rej)}"}
    allu = [u for r in rows for u in r["usage"]]
    tin, tout, c = cost(price_in, price_out, allu)
    out["summary"]["tokens"] = {"in": tin, "out": tout, "calls": len(rows),
                                "cost_usd": c, "cost_per_scan_usd": (c / len(rows)) if (c is not None and rows) else None}
    return out


# ============================================================== safety evaluation (offline)
def eval_safety():
    tp = sum(safety.detect_emergency(q) is not None for q in cases.EMERGENCY_YES)
    fp_list = [q for q in cases.EMERGENCY_NO if safety.detect_emergency(q) is not None]
    missed = [q for q in cases.EMERGENCY_YES if safety.detect_emergency(q) is None]

    rule_ok, rule_bad = 0, []
    for meds, allergies, conditions, expected in cases.RULE_CASES:
        got = rules.check_all([{"name": m, "dosage": "500 mg", "times": ["08:00"]} for m in meds], allergies, conditions)
        sev = "high" if any(w.severity == "high" for w in got) else ("caution" if got else None)
        if sev == expected:
            rule_ok += 1
        else:
            rule_bad.append((meds, allergies, conditions, expected, sev))
    return {
        "emergency_recall": f"{tp}/{len(cases.EMERGENCY_YES)}",
        "emergency_missed": missed,
        "emergency_false_alarms": f"{len(fp_list)}/{len(cases.EMERGENCY_NO)}",
        "false_alarm_examples": fp_list,
        "rules_correct": f"{rule_ok}/{len(cases.RULE_CASES)}",
        "rules_wrong": rule_bad,
    }


# ============================================================== agent evaluation
AGENT_TABLES = {
    "sleep_logs": [{"hours": 5.5, "logged_at": "2026-10-22T03:00:00Z"}, {"hours": 6.0, "logged_at": "2026-10-23T03:00:00Z"}],
    "water_logs": [{"amount_ml": 900, "logged_at": "2026-10-23T05:00:00Z"}],
    "mood_logs": [{"mood": "low", "logged_at": "2026-10-23T05:00:00Z"}],
    "wearable_samples": [{"value": 72, "recorded_at": "2026-10-23T05:00:00Z", "context": "resting"}],
    "medications": [{"name": "Amoxicillin", "dosage": "500 mg", "times": ["08:00", "20:00"], "start_date": None, "end_date": None}],
    "allergies": [{"name": "Penicillin"}],
    "lab_results": [{"test_name": "Haemoglobin", "value": 11.2, "value_text": None, "unit": "g/dL", "ref_low": 13,
                     "ref_high": 17, "flag": "low", "reported_on": "2026-10-20"}],
    "period_logs": [{"start_date": "2026-10-01", "end_date": "2026-10-05"}, {"start_date": "2026-09-03", "end_date": "2026-09-07"}],
    "profiles": [{"birth_date": "2000-10-20", "sex": "female", "blood_type": "O+", "height_cm": 165, "weight_kg": 58,
                  "conditions": [], "goals": []}],
}


async def eval_agent(price_in, price_out, *, authorize, live: bool):
    rows = []
    group_by_tool = {tool: group for group, names in agent.HEALTH_TOOLS.items() for tool in names}
    db = FakeDB(AGENT_TABLES)
    for c in cases.AGENT_CASES:
        u0, t0 = len(llm.USAGE), time.perf_counter()
        try:
            if live:
                await asyncio.sleep(20)
            res = await agent.run_agent(
                c["q"], db, authorize=authorize, health_data={group_by_tool[c["tool"]]},
            )
        except llm.LLMError as e:
            rows.append({"q": c["q"], "error": e.message})
            continue
        used = [s for s in res.steps if s.get("ok")]
        tool_ok = any(s["tool"] == c["tool"] and ("kind" not in c or s["args"].get("kind") == c["kind"]) for s in used)
        low = res.reply.lower()
        rows.append({
            "q": c["q"], "tool_ok": tool_ok, "tools": [s["tool"] for s in used],
            "disclaimer": res.reply.rstrip().endswith(safety.DISCLAIMER),
            "unsafe": any(p in low for p in cases.FORBIDDEN_IN_REPLIES),
            "steps": len(res.steps), "seconds": time.perf_counter() - t0,
            "tokens": sum(u["in"] + u["out"] for u in llm.USAGE[u0:]),
        })
    ok = [r for r in rows if "error" not in r]
    emerg = [q for q in cases.EMERGENCY_YES[:5]]
    emerg_ok = 0
    for q in emerg:
        r = await agent.run_agent(q, db, authorize=authorize)
        emerg_ok += bool(r.emergency)
    allu = [u for u in llm.USAGE]
    tin, tout, cst = cost(price_in, price_out, allu)
    return {
        "rows": rows,
        "summary": {
            "right_tool": f"{sum(r['tool_ok'] for r in ok)}/{len(ok)}" if ok else "n/a",
            "disclaimer_present": f"{sum(r['disclaimer'] for r in ok)}/{len(ok)}" if ok else "n/a",
            "unsafe_wording": f"{sum(r['unsafe'] for r in ok)}/{len(ok)}" if ok else "n/a",
            "avg_steps": round(sum(r['steps'] for r in ok) / len(ok), 1) if ok else None,
            "p50_s": metrics.percentile([r["seconds"] for r in ok], 0.5) if ok else None,
            "emergency_bypass": f"{emerg_ok}/{len(emerg)}",
            "errors": len(rows) - len(ok),
            "cost_usd": cst,
        },
    }


# ============================================================== report
def markdown(results, args):
    L = [f"# NOVA Health evaluation ({datetime.now():%Y-%m-%d %H:%M})", ""]
    model = "mock" if args.mock else os.environ["LLM_MODEL"] if args.live_synthetic else "none"
    mode = "MOCK model (checks the script only)" if args.mock else "live synthetic" if args.live_synthetic else "offline safety"
    L.append(f"Model: `{model}`  |  runs per image: {args.runs}  |  {mode}")
    s = results.get("scans", {}).get("summary")
    if s:
        L += ["", "## Scans", "", "| Task | Items found | Precision | Recall | F1 (mean ± sd) | Field accuracy | p50 s | p95 s |", "|---|---|---|---|---|---|---|---|"]
        for t in ("prescription", "report"):
            if t in s:
                x = s[t]
                fa = ", ".join(f"{k} {v}" for k, v in x["fields"].items())
                L.append(f"| {t} | {x['items_found']} | {x['precision']:.2f} | {x['recall']:.2f} | {x['f1_mean']:.2f} ± {x['f1_sd']:.2f} | {fa} | {x['p50_s']:.1f} | {x['p95_s']:.1f} |")
        if "rejection" in s:
            L.append(f"\nWrong-document rejection: **{s['rejection']['correct']}** correct.")
        t = s["tokens"]
        L.append(f"\nTokens: {t['in']} in, {t['out']} out over {t['calls']} calls." + (
            f" Estimated cost: ${t['cost_usd']:.4f} total, ${t['cost_per_scan_usd']:.5f} per scan." if t["cost_usd"] is not None else
            " (Give --price-in and --price-out to estimate cost.)"))
    s = results.get("safety")
    if s:
        L += ["", "## Safety (fixed rules, no AI)", "",
              f"- Emergency wording recognised: **{s['emergency_recall']}**; false alarms on normal questions: **{s['emergency_false_alarms']}**",
              f"- Medicine rule cases correct: **{s['rules_correct']}**"]
        if s["emergency_missed"]:
            L.append("- Missed emergencies: " + "; ".join(s["emergency_missed"]))
        if s["false_alarm_examples"]:
            L.append("- False alarms: " + "; ".join(s["false_alarm_examples"]))
        for meds, al, co, exp, got in s["rules_wrong"]:
            L.append(f"- Rule mismatch: {meds} allergies={al} conditions={co} expected={exp} got={got}")
    s = results.get("agent", {}).get("summary")
    if s:
        L += ["", "## Assistant (agent)", "",
              f"- Right tool chosen: **{s['right_tool']}**; disclaimer present: **{s['disclaimer_present']}**; unsafe wording: **{s['unsafe_wording']}**",
              f"- Average steps: {s['avg_steps']}; median time: {s['p50_s'] if s['p50_s'] is None else round(s['p50_s'], 1)} s; emergency bypass (no AI call): **{s['emergency_bypass']}**; errors: {s['errors']}"]
        if s["cost_usd"] is not None:
            L.append(f"- Estimated cost: ${s['cost_usd']:.4f}")
    return "\n".join(L) + "\n"


async def live_authorizer():
    """Verify current consent for the explicitly configured evaluation account."""
    ai_privacy.require_provider()
    token = os.environ.get("NOVA_EVAL_ACCESS_TOKEN", "").strip()
    if not token or not all(os.environ.get(key) for key in ("SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY")):
        raise ValueError("Configure the approved synthetic evaluation account before making live requests.")

    import main as api
    from db import UserDB

    user = await api.current_user(f"Bearer {token}")
    authorize = partial(ai_privacy.require_consent, UserDB(token, user["id"]))
    await authorize()
    return authorize


async def block_mock_http(*args, **kwargs):
    raise RuntimeError("Outbound HTTP is disabled in mock evaluation.")


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", type=Path, default=SYNTHETIC_IMAGE_DIR, help="synthetic image folder for mock evaluations")
    ap.add_argument("--output-dir", type=Path, default=HERE / "results")
    ap.add_argument("--scans", action="store_true")
    ap.add_argument("--safety", action="store_true")
    ap.add_argument("--agent", action="store_true")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--runs", type=int, default=1)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--mock", action="store_true", help="use a fake model and block outbound HTTP")
    mode.add_argument("--live-synthetic", action="store_true", help="use approved external AI for built-in synthetic cases")
    ap.add_argument("--mock-noise", type=float, default=0.0, help="share of fields the mock gets wrong (0 to 1)")
    ap.add_argument("--price-in", type=float, default=None, help="USD per 1M input tokens")
    ap.add_argument("--price-out", type=float, default=None, help="USD per 1M output tokens")
    args = ap.parse_args()
    if args.runs < 1:
        ap.error("--runs must be at least 1")
    if args.all or not (args.scans or args.safety or args.agent):
        args.scans = args.safety = args.agent = True
    if args.live_synthetic and (not (args.scans or args.agent) or args.images.resolve() != SYNTHETIC_IMAGE_DIR.resolve()):
        ap.error("--live-synthetic requires a model evaluation and the built-in synthetic fixtures.")
    if (args.scans or args.agent) and not args.live_synthetic:
        args.mock = True

    results = {}
    with ExitStack() as overrides:
        authorize = None
        if args.mock:
            overrides.enter_context(patch.object(httpx.AsyncClient, "send", block_mock_http))
            overrides.enter_context(patch.dict(os.environ, {
                "AI_PRIVACY_PROVIDER_APPROVAL": "gemini-reviewed-paid",
                "LLM_API_KEY": "synthetic-evaluation-key",
                "LLM_MODEL": "gemini-evaluation-mock",
            }))
            consent_db = FakeDB({
                "ai_processing_consents": [{"disclosure_version": ai_privacy.DISCLOSURE_VERSION}],
            })
            authorize = partial(ai_privacy.require_consent, consent_db)
        elif args.live_synthetic:
            authorize = await live_authorizer()

        documents = await prepare_documents(args.images, live=args.live_synthetic) if args.scans else {}
        if args.mock:
            overrides.enter_context(patch.object(llm, "generate_json", MockModel(documents, args.mock_noise)))
        if args.safety:
            print("Safety evaluation (offline)...")
            results["safety"] = eval_safety()
        if args.scans:
            print(f"Scan evaluation ({len(documents)} reviewed documents x {args.runs} run(s))...")
            llm.USAGE.clear()
            results["scans"] = await eval_scans(
                documents, args.runs, args.price_in, args.price_out, authorize=authorize,
            )
        if args.agent:
            print("Agent evaluation...")
            llm.USAGE.clear()
            results["agent"] = await eval_agent(
                args.price_in, args.price_out, authorize=authorize, live=args.live_synthetic,
            )

    md = markdown(results, args)
    print("\n" + md)
    out = args.output_dir
    out.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S") + ("_mock" if args.mock else "")
    markdown_path = out / f"eval_{stamp}.md"
    json_path = out / f"eval_{stamp}.json"
    markdown_path.write_text(md)
    slim = json.loads(json.dumps(results, default=str))
    for sec in ("scans",):
        for r in slim.get(sec, {}).get("rows", []):
            r.pop("usage", None)
    json_path.write_text(json.dumps(slim, indent=2))
    print(f"Saved {markdown_path} and {json_path}")


if __name__ == "__main__":
    asyncio.run(main())
