"""
NOVA Health: AI engine starter (ai-engine/engine.py)

Runs offline with fake data and a stub LLM.
Replace call_llm() with a real provider call (Claude, Gemini, OpenAI)
once the team picks one. Keep API keys in environment variables.
"""

import json
from datetime import date, timedelta

# ---------------------------------------------------------------
# 1. Fake data layer (replace with real database queries later)
# ---------------------------------------------------------------

FAKE_DB = {
    "sleep_hours": [6.0, 5.0, 5.5, 5.0, 6.0, 5.5, 5.5],
    "water_ml": [900, 1200, 800, 700, 1500, 800, 900],
    "mood": ["ok", "low", "low", "ok", "good", "low", "ok"],
    "medications": [{"name": "Sample Medicine", "dosage": "500 mg", "times": ["08:00", "20:00"]}],
}


def get_sleep(days: int = 7):
    return FAKE_DB["sleep_hours"][-days:]


def get_water(days: int = 7):
    return FAKE_DB["water_ml"][-days:]


def get_mood(days: int = 7):
    return FAKE_DB["mood"][-days:]


def get_medications():
    return FAKE_DB["medications"]


# Tools the LLM is allowed to call (the "agentic" part)
TOOLS = {
    "get_sleep": get_sleep,
    "get_water": get_water,
    "get_mood": get_mood,
    "get_medications": get_medications,
}

# ---------------------------------------------------------------
# 2. Context builder
# ---------------------------------------------------------------


def build_context(user_id: str, days: int = 7) -> str:
    """Turn recent data into a short text summary for the LLM.
    Do not include names or IDs in the text sent to the model."""
    sleep = get_sleep(days)
    water = get_water(days)
    mood = get_mood(days)
    meds = get_medications()

    return (
        f"Last {days} days summary:\n"
        f"- Average sleep: {sum(sleep) / len(sleep):.1f} hours\n"
        f"- Average water: {sum(water) / len(water):.0f} ml/day\n"
        f"- Low mood days: {mood.count('low')}\n"
        f"- Current medications: {', '.join(m['name'] for m in meds) or 'none'}\n"
    )


# ---------------------------------------------------------------
# 3. Prompt and safety
# ---------------------------------------------------------------

SYSTEM_PROMPT = """You are NOVA, a personal health assistant.
Rules:
1. Give general wellness guidance only. Never diagnose.
2. Use only the data provided. If data is missing, say so.
3. For anything serious, advise the user to see a doctor.
4. Be short, clear, and friendly.
"""

DISCLAIMER = "\n\nThis is guidance, not medical advice."

BLOCKED_PHRASES = ["you have been diagnosed", "you definitely have"]


def safety_check(reply: str) -> str:
    """Basic output filter. Extend this with the team's safety rules."""
    lowered = reply.lower()
    if any(p in lowered for p in BLOCKED_PHRASES):
        reply = "I cannot diagnose conditions. Please talk to a doctor about this."
    return reply + DISCLAIMER


# ---------------------------------------------------------------
# 4. LLM call (stub)
# ---------------------------------------------------------------


def call_llm(system_prompt: str, user_prompt: str) -> str:
    """STUB. Replace with a real API call, for example:

        response = client.messages.create(
            model="<model-name>",
            max_tokens=500,
            system=system_prompt,
            messages=[{"role": "user", "content": user_prompt}],
        )
        return response.content[0].text

    Read the key with os.environ["LLM_API_KEY"]. Never hardcode it.
    """
    return (
        "Your sleep averaged about 5.5 hours and water intake was low on several "
        "days. Try going to bed earlier and drinking more water through the day."
    )


# ---------------------------------------------------------------
# 5. Public functions (called by the backend)
# ---------------------------------------------------------------


def answer_question(user_id: str, message: str) -> dict:
    context = build_context(user_id)
    user_prompt = f"User health context:\n{context}\nQuestion: {message}"
    raw_reply = call_llm(SYSTEM_PROMPT, user_prompt)
    return {"reply": safety_check(raw_reply), "sources": ["sleep", "water", "mood"]}


def generate_daily_report(user_id: str, report_date: date | None = None) -> dict:
    report_date = report_date or date.today()
    context = build_context(user_id, days=1)
    user_prompt = f"Write a short daily health report.\n{context}"
    raw_reply = call_llm(SYSTEM_PROMPT, user_prompt)
    return {"date": report_date.isoformat(), "report": safety_check(raw_reply)}


# TODO (later):
# - analyze_prescription(image_bytes) -> structured JSON (OCR + vision)
# - analyze_food(image_bytes) -> estimated nutrition
# - real tool-calling loop: send TOOLS to the LLM, run the function it picks,
#   return the result to the LLM, repeat until it gives a final answer


if __name__ == "__main__":
    print(json.dumps(answer_question("demo-user", "Why am I tired this week?"), indent=2))
