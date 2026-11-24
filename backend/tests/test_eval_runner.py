import asyncio
import json
import sys

import httpx
import pytest

from eval import cases, run_eval


def test_mock_evaluation_exercises_scans_and_agent_without_network(monkeypatch, tmp_path):
    monkeypatch.delenv("NOVA_EVAL_ACCESS_TOKEN", raising=False)
    monkeypatch.setenv("LLM_MODEL", "must-not-use-real-model")
    monkeypatch.setattr(sys, "argv", ["run_eval", "--mock", "--all", "--output-dir", str(tmp_path)])
    texts = {
        image.read_bytes(): "\n".join([
            "Patient: Synthetic Person", f"Synthetic fixture {image.stem}",
            *(" ".join(part for part in (row["test"], row["value_text"], row["unit"], row["reference_text"]) if part)
              for row in cases.REPORTS.get(image.name, [])),
        ])
        for image in run_eval.SYNTHETIC_IMAGE_DIR.glob("*.jpg")
    }

    async def fake_local_ocr(original):
        async with httpx.AsyncClient() as client:
            with pytest.raises(RuntimeError, match="Outbound HTTP is disabled in mock evaluation"):
                await client.get("https://network-must-be-blocked.invalid/")
        return texts[original]

    monkeypatch.setattr(run_eval.ai_privacy, "extract_medical_text", fake_local_ocr)
    asyncio.run(run_eval.main())

    report = json.loads(next(tmp_path.glob("*_mock.json")).read_text())
    scans = report["scans"]["summary"]
    assert scans["prescription"]["items_found"] == "3/3"
    assert scans["report"]["items_found"] == "12/12"
    assert scans["report"]["fields"] == {"value": "100%", "unit": "100%", "range": "100%", "flag": "100%"}
    assert scans["rejection"]["correct"] == "4/4"
    assert report["agent"]["summary"]["right_tool"] == "10/10"
    assert report["agent"]["summary"]["emergency_bypass"] == "5/5"
    assert report["agent"]["summary"]["errors"] == 0
    assert report["safety"]["rules_correct"] == "20/20"
    assert "`mock`" in next(tmp_path.glob("*_mock.md")).read_text()
