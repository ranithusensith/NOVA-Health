"""
Safety layer around the AI. Fixed rules, never decided by the model.

1. redact()            removes emails, phone numbers and ID numbers before text reaches the AI
2. detect_emergency()  recognises red-flag messages BEFORE any AI call
3. guard_output()      blocks diagnosis-style wording in AI answers
4. finalize()          adds rule-engine safety notes and the disclaimer

Emergency numbers (Sri Lanka): 1990 free ambulance (Suwa Seriya), 119 police,
1926 National Mental Health Helpline (24/7, free). English keywords only for now.
"""

import re

DISCLAIMER = "Guidance, not medical advice."
MAX_REPLY_CHARS = 1200

# ---------------------------------------------------------------- redaction
_EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")
_NIC = re.compile(r"\b(?:\d{9}[vVxX]|\d{12})\b")
_PHONE = re.compile(r"(?<!\w)(?:\+?\d[\d\s().-]{6,}\d)(?!\w)")


def redact(text: str) -> str:
    text = _EMAIL.sub("[email]", text)
    text = _NIC.sub("[id]", text)
    text = _PHONE.sub("[phone]", text)
    return text


# ---------------------------------------------------------------- emergencies
_SELF_HARM = [
    "kill myself", "end my life", "want to die", "wanna die", "suicid", "hurt myself",
    "self harm", "self-harm", "don't want to live", "dont want to live", "better off dead",
    "ending my life", "end my own life", "take my own life", "taking my own life", "end it all",
    "ending it all", "no reason to live", "not worth living", "wish i was dead", "wish i were dead",
]
_MEDICAL = [
    "chest pain", "pain in my chest", "can't breathe", "cant breathe", "cannot breathe",
    "can not breathe", "trouble breathing", "difficulty breathing", "hard to breathe",
    "not breathing", "heart attack", "stroke", "face drooping", "slurred speech",
    "unconscious", "passed out", "fainted", "seizure", "convulsion", "severe bleeding",
    "bleeding heavily", "bleeding a lot", "coughing blood", "coughing up blood", "vomiting blood",
    "overdose", "took too many", "swallowed poison", "poisoned", "anaphyla", "throat is closing",
    "throat closing", "tongue is swelling", "swelling of my throat", "severe allergic reaction",
]


# "What is stroke?" or "Explain what a heart attack is" are questions about a word, not an emergency.
# They only count as general questions when nobody (I, my, he, she, my mother...) is mentioned.
_GENERAL_QUESTION = re.compile(r"^(what is|what's|what are|explain|define|describe|tell me about|meaning of)\b")
_PERSON = re.compile(
    r"\b(i|i'm|im|i've|ive|my|me|we|he|she|they|him|her|someone|somebody|mom|mum|mother|father|dad|"
    r"baby|child|son|daughter|friend|husband|wife|brother|sister)\b"
)


def detect_emergency(text: str) -> str | None:
    """Returns 'self_harm', 'medical' or None."""
    t = re.sub(r"\s+", " ", text.lower()).strip()
    if any(k in t for k in _SELF_HARM):
        return "self_harm"
    if any(k in t for k in _MEDICAL):
        if _GENERAL_QUESTION.match(t) and not _PERSON.search(t):
            return None
        return "medical"
    return None


def emergency_reply(kind: str) -> str:
    if kind == "self_harm":
        return (
            "I'm really sorry you are feeling this way, and I'm glad you said it. You do not have to "
            "face this alone.\n\n"
            "- Call 1926 (National Mental Health Helpline, free, 24 hours) or send them a text.\n"
            "- If you might act on these thoughts right now, call 1990 for an ambulance or go to the "
            "nearest hospital, and ask someone you trust to stay with you.\n\n"
            "Please reach out to one of these now. I'm here, but they can help you in ways I can't."
        )
    return (
        "This could be an emergency. Please do not wait for the app.\n\n"
        "- Call 1990 (free ambulance, Suwa Seriya) now, or go to the nearest hospital.\n"
        "- If someone is unconscious or not breathing, call 1990 first and follow the operator's instructions.\n"
        "- Stay with the person and keep them as calm and still as you can.\n\n"
        "You can also open the SOS screen in NOVA Health to alert your emergency contacts."
    )


# ---------------------------------------------------------------- output guard
_BLOCKED = [
    "you have been diagnosed", "you are diagnosed", "you definitely have", "you certainly have",
    "you are suffering from", "i diagnose", "this is definitely", "stop taking your medication",
    "stop taking your medicine", "increase your dose", "double your dose", "take more of",
]
_SAFE_FALLBACK = (
    "I can't tell you what condition this is or change your treatment. Please talk to a doctor or "
    "pharmacist about it, and get medical help quickly if you feel very unwell."
)

_MED_WORDS = re.compile(
    r"\b(medicine|medicines|medication|medications|pill|pills|tablet|tablets|capsule|dose|doses|drug|"
    r"drugs|allerg\w*|antibiotic\w*|painkiller\w*|prescription)\b",
    re.I,
)


def guard_output(text: str) -> str:
    t = text.strip()
    low = t.lower()
    if any(b in low for b in _BLOCKED):
        return _SAFE_FALLBACK
    if len(t) > MAX_REPLY_CHARS:
        t = t[:MAX_REPLY_CHARS].rsplit(" ", 1)[0] + "…"
    return t


def finalize(answer: str, notes: list[dict], question: str) -> str:
    """Guard the answer, add rule-engine notes when relevant, add the disclaimer."""
    text = guard_output(answer)
    show_notes = False
    if notes:
        if _MED_WORDS.search(question):
            show_notes = True
        else:
            low = text.lower()
            show_notes = any(n.get("subject", "").lower() in low for n in notes if n.get("subject"))
    if show_notes:
        lines = [f"- {n['message']}" for n in notes[:3]]
        text += "\n\nSafety notes:\n" + "\n".join(lines)
    return f"{text}\n\n{DISCLAIMER}"
