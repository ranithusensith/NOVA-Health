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
_PHONE = re.compile(r"(?<![\w-])(?!(?:\d{4}-\d{2}-\d{2}|\d{1,2}-\d{1,2}-\d{4})\b)(?:\+?\d[0-9 ().-]{6,}\d)(?!\w)")
_LAB_RANGE = re.compile(r"[1-9]\d{3,5}[ \t]*-[ \t]*[1-9]\d{3,5}")
_LAB_RANGE_CONTEXT = re.compile(r"\b(?:ref(?:erence)?|range|wbc|rbc|platelets)\b|/[uµμ]l\b", re.I)
_PHONE_LABEL = re.compile(
    r"\b(?:phone|mobile|tel(?:ephone)?|fax)\s*(?:number|no\.?)?\s*[:=]\s*"
    r"(?:\+?\d[0-9 ().-]{6,}\d)(?!\w)", re.I,
)
_UUID = re.compile(r"\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b", re.I)
_URL = re.compile(r"\b(?:https?://|www\.)[^\s<>]+", re.I)
_ID_LABEL = re.compile(
    r"\b(?:(?:patient|national|medical record|record|hospital|visit|sample|accession|lab|passport|insurance)"
    r"\s*(?:id|no\.?|number|#)\s*[:#=-]?|(?:id|mrn|nic)\s*[:#=])\s*[\w-]+", re.I,
)
_NAME_LABEL = re.compile(
    r"\b(?:my name is|(?:patient|provider|doctor|full)\s+name\s*[:=]|name\s*[:=])"
    r"\s*[^\W\d_][^,;.!?\n]{0,90}", re.I,
)
_IDENTITY_LINE = re.compile(
    r"^\s*(?:patient(?:\s+name)?|name|doctor|physician|provider|prescriber|ordered by|referred by|"
    r"collected by|reviewed by|signed by|address|dob|date of birth|birth date|phone|tel|fax|"
    r"e-?mail|mrn|nic|passport|insurance|(?:medical record|patient|hospital|visit|sample|accession|lab)"
    r"\s*(?:id|no\.?|number|#))\s*[:#=.-]\s*.*$", re.I,
)
_ADDRESS = re.compile(
    r"\b\d{1,6}\s+(?:[^\W\d_]+\s+){1,5}(?:street|road|lane|avenue|drive|boulevard)\b", re.I,
)
_EXACT_DATE = re.compile(r"\b(?:\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}[-/]\d{1,2}[-/]\d{4})\b")
_DOB = re.compile(
    r"\b(?:dob|date of birth|birth date|born on)\s*[:=]?\s*"
    r"(?:\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}|\d{1,2}\s+[a-z]+\s+\d{4})\b", re.I,
)


def redact(
    text: str, known_identifiers: tuple[str, ...] = (), *, clinical_ranges: bool = False,
) -> str:
    for identity in sorted(set(known_identifiers), key=len, reverse=True):
        identity = identity.strip()
        if len(identity) >= 2:
            text = re.sub(r"(?<!\w)" + re.escape(identity) + r"(?!\w)", "[redacted]", text, flags=re.I)
    for pattern, placeholder in (
        (_URL, "[link]"), (_EMAIL, "[email]"), (_UUID, "[id]"), (_NIC, "[id]"),
        (_ID_LABEL, "[id]"), (_NAME_LABEL, "[name]"), (_ADDRESS, "[address]"),
        (_DOB, "[birth date]"), (_PHONE_LABEL, "[phone]"),
    ):
        text = pattern.sub(placeholder, text)
    def phone_or_range(match: re.Match) -> str:
        candidate = match[0]
        # A range in lab context can look like a phone number. Labeled
        # contact details have already been removed.
        if clinical_ranges and _LAB_RANGE.fullmatch(candidate):
            return candidate
        return "[phone]" if sum(char.isdigit() for char in candidate) >= 8 else candidate

    return _PHONE.sub(phone_or_range, text)


def redact_chat(text: str, known_identifiers: tuple[str, ...]) -> str:
    return _EXACT_DATE.sub("[date]", redact(text, known_identifiers))


def is_identity_line(line: str) -> bool:
    return _IDENTITY_LINE.fullmatch(line) is not None


def clinical_text(text: str, known_identifiers: tuple[str, ...] = ()) -> str:
    """Drop common document headers and redact remaining direct identifiers."""
    return "\n".join(
        cleaned for line in text.splitlines()
        if not is_identity_line(line)
        if (cleaned := redact(
            line, known_identifiers, clinical_ranges=_LAB_RANGE_CONTEXT.search(line) is not None,
        ).strip())
    )


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
