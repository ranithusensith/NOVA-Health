import asyncio

import pytest

import agent
import llm
import safety
from fakes import FakeDB, script_llm


def run(coro):
    return asyncio.run(coro)


SLEEP_ROWS = [
    {"hours": 5, "logged_at": "2026-10-22T03:00:00Z"},
    {"hours": 6, "logged_at": "2026-10-23T03:00:00Z"},
]


def test_tool_call_then_final_answer(monkeypatch):
    prompts = []
    script_llm(monkeypatch, [
        {"action": "tool", "tool": "get_recent_logs", "args": {"kind": "sleep", "days": 7}},
        {"action": "final", "answer": "You slept about 5.5 hours a night.", "used": ["sleep"]},
    ], prompts)
    res = run(agent.run_agent("How did I sleep this week?", FakeDB({"sleep_logs": SLEEP_ROWS}), health_data={"logs"}))
    assert "5.5 hours" in res.reply
    assert res.reply.rstrip().endswith(safety.DISCLAIMER)
    assert res.sources == ["sleep"]
    assert res.steps[0]["tool"] == "get_recent_logs" and res.steps[0]["ok"] is True
    # the tool result was passed back to the model
    assert "average_hours_on_logged_days" in prompts[1]
    assert res.emergency is False


def test_emergency_never_calls_the_model(monkeypatch):
    def boom(*a, **k):
        raise AssertionError("the model must not be called for an emergency")

    monkeypatch.setattr(llm, "generate_json", boom)
    res = run(agent.run_agent("I have chest pain and feel faint", FakeDB()))
    assert res.emergency is True and "1990" in res.reply


def test_self_harm_message_gets_the_helpline(monkeypatch):
    monkeypatch.setattr(llm, "generate_json", lambda *a, **k: (_ for _ in ()).throw(AssertionError("no model")))
    res = run(agent.run_agent("I want to end my life", FakeDB()))
    assert res.emergency is True and "1926" in res.reply


def test_prompt_never_contains_contact_details(monkeypatch):
    prompts = []
    script_llm(monkeypatch, [{"action": "final", "answer": "Okay.", "used": []}], prompts)
    run(agent.run_agent("my email is ana@example.com and my phone is 0771234567, am I sleeping enough?", FakeDB()))
    assert "ana@example.com" not in prompts[0] and "0771234567" not in prompts[0]
    assert "[email]" in prompts[0] and "[phone]" in prompts[0]


def test_loop_is_bounded_and_forces_a_final_answer(monkeypatch):
    prompts = []
    script_llm(monkeypatch, [
        {"action": "tool", "tool": "get_profile", "args": {}},
        {"action": "tool", "tool": "get_allergies", "args": {}},
        {"action": "final", "answer": "Here is what I found.", "used": ["profile"]},
    ], prompts)
    res = run(agent.run_agent("Tell me about me", FakeDB(), max_steps=2, health_data={"profile", "medications"}))
    assert len(prompts) == 3  # 2 steps + 1 forced final
    assert "Now answer" in prompts[2]
    assert "Here is what I found" in res.reply


def test_malformed_step_is_survived(monkeypatch):
    script_llm(monkeypatch, [
        {"action": "dance"},
        {"action": "final", "answer": "Done.", "used": []},
    ])
    res = run(agent.run_agent("hello", FakeDB()))
    assert res.steps[0]["note"] == "bad step"
    assert "Done." in res.reply


def test_repeated_tool_call_is_not_run_twice(monkeypatch):
    db = FakeDB({"sleep_logs": SLEEP_ROWS})
    script_llm(monkeypatch, [
        {"action": "tool", "tool": "get_recent_logs", "args": {"kind": "sleep"}},
        {"action": "tool", "tool": "get_recent_logs", "args": {"kind": "sleep"}},
        {"action": "final", "answer": "Fine.", "used": []},
    ])
    res = run(agent.run_agent("sleep?", db, health_data={"logs"}))
    assert [s.get("note") for s in res.steps] == [None, "repeat"]
    assert sum(1 for t, *_ in db.selects if t == "sleep_logs") == 1


def test_bad_tool_arguments_do_not_crash(monkeypatch):
    script_llm(monkeypatch, [
        {"action": "tool", "tool": "get_recent_logs", "args": {"kind": "blood"}},
        {"action": "tool", "tool": "no_such_tool", "args": {}},
        {"action": "final", "answer": "I could not read that.", "used": []},
    ])
    res = run(agent.run_agent("what is my blood?", FakeDB(), health_data={"logs"}))
    assert all(s["ok"] is False for s in res.steps[:2])
    assert "could not read" in res.reply


def test_database_failure_is_reported_to_the_model_not_the_user(monkeypatch):
    from db import DBError

    prompts = []
    script_llm(monkeypatch, [
        {"action": "tool", "tool": "get_recent_logs", "args": {"kind": "water"}},
        {"action": "final", "answer": "I could not read your water logs right now.", "used": []},
    ], prompts)
    res = run(agent.run_agent("water?", FakeDB({"water_logs": DBError("down")}), health_data={"logs"}))
    assert "Could not read this data right now" in prompts[1]
    assert res.steps[0]["ok"] is False


def test_unsafe_answer_is_replaced(monkeypatch):
    script_llm(monkeypatch, [{"action": "final", "answer": "You definitely have diabetes.", "used": []}])
    res = run(agent.run_agent("why am I thirsty?", FakeDB()))
    assert "diabetes" not in res.reply.lower()
    assert "doctor or pharmacist" in res.reply


def test_allergy_conflict_is_added_by_fixed_rules_even_if_the_model_ignores_it(monkeypatch):
    db = FakeDB({
        "medications": [{"name": "Amoxicillin", "dosage": "500 mg", "times": ["08:00", "20:00"],
                         "start_date": None, "end_date": None}],
        "allergies": [{"name": "Penicillin"}],
    })
    prompts = []
    script_llm(monkeypatch, [{"action": "final", "answer": "Take it with water.", "used": []}], prompts)
    res = run(agent.run_agent("Can I take my medicine with food?", db, health_data={"medications"}))
    assert "SAFETY NOTES" in prompts[0]
    assert "Amoxicillin" not in prompts[0] and "Penicillin" not in prompts[0]
    assert "Safety notes" in res.reply and "Amoxicillin" in res.reply
    assert res.warnings and res.warnings[0]["severity"] == "high"


def test_model_errors_propagate_so_the_api_can_report_them(monkeypatch):
    script_llm(monkeypatch, [llm.LLMError("busy", 429)])
    with pytest.raises(llm.LLMError):
        run(agent.run_agent("hello", FakeDB()))


def test_history_is_included_in_the_prompt(monkeypatch):
    prompts = []
    script_llm(monkeypatch, [{"action": "final", "answer": "Sure.", "used": []}], prompts)
    history = [{"role": "user", "content": "I felt dizzy yesterday"}, {"role": "assistant", "content": "Rest and drink water."}]
    run(agent.run_agent("and today?", FakeDB(), history=history))
    assert "RECENT CONVERSATION" in prompts[0] and "dizzy yesterday" in prompts[0]
