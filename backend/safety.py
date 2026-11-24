"""
Safety layer around the AI. Fixed rules, never decided by the model.

1. redact()            removes emails, phone numbers and ID numbers before text reaches the AI
2. detect_emergency()  recognises red-flag messages BEFORE any AI call
3. guard_output()      blocks common unsafe treatment and diagnosis wording
4. finalize()          adds rule-engine safety notes and the disclaimer

Emergency detection uses a limited English and Sinhala vocabulary.
"""

import re
import unicodedata

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
_SELF_HARM = re.compile(
    r"\b(?:kill (?:myself|himself|herself|themselves)|end (?:my|his|her|their) (?:own )?life|"
    r"(?:want to|wanna) die|suicid(?:e|al)|hurt myself|self[ -]harm|don'?t want to live|"
    r"better off dead|ending my life|tak(?:e|ing) my own life|end(?:ing)? it all|"
    r"no reason to live|not worth living|wish i (?:was|were) dead)\b"
)
_MEDICAL = re.compile(
    r"\b(?:chest (?:pain|pressure|tightness|heaviness)|"
    r"(?:pain|pressure|tightness) in (?:my|the|his|her) chest|"
    r"(?:can'?t|cannot|can not) (?:breathe|catch (?:my|his|her) breath)|not breathing|gasping|"
    r"(?:trouble|difficulty) breathing|hard to breathe|struggling to breathe|"
    r"heart attack|stroke|fac(?:e|ial) (?:is )?droop(?:s|ing)?|slurred speech|"
    r"one[ -]sided weakness|(?:can'?t|cannot) (?:move (?:one|my|his|her) arm|speak)|"
    r"unconscious|unresponsive|passed out|fainted|won'?t wake up|seizures?|convulsions?|"
    r"(?:severe|heavy) bleeding|bleeding (?:heavily|a lot|won'?t stop)|"
    r"(?:coughing(?: up)?|vomiting|throwing up) blood|choking|"
    r"overdos(?:e|ed)|(?:took|taken|swallowed) too (?:many|much)|swallowed poison|"
    r"poisoned|anaphylaxis|throat (?:is )?closing|tongue (?:is )?swelling|"
    r"swelling of my throat|severe allergic reaction)\b"
)
_SINHALA_SELF_HARM = (
    "මට මැරෙන්න ඕන", "ජීවිතේ නැති කරගන්න", "ජීවිතය නැති කරගන්න", "සියදිවි නසාගන්න", "සියදිවි නසා ගැනීමට",
)
_SINHALA_MEDICAL = (
    "පපුව රිදෙනවා", "පපුවේ වේදනාව", "පපුවේ කැක්කුම", "පපුව තද වෙනවා",
    "හුස්ම ගන්න බෑ", "හුස්ම ගන්න බැහැ", "හුස්ම ගන්න බැරි", "හුස්ම ගන්න අමාරු",
    "හුස්ම ගන්නේ නෑ", "හුස්ම ගන්නෙ නෑ", "හුස්ම ගන්නේ නැහැ", "හුස්ම හිර",
    "සිහිය නැහැ", "සිහිය නෑ", "සිහිය නැති", "ලේ ගොඩක් යනවා", "ලේ නවතින්නේ නැහැ",
    "ලේ වමනය", "විෂ බීලා", "බෙහෙත් වැඩිපුර ගත්තා", "බෙහෙත් ගොඩක් බිව්වා",
    "මූණ පැත්තකට වැටිලා", "වලිප්පුව හැදිලා",
)
_SINHALA = re.compile(r"[\u0d80-\u0dff]")
_PERSON = re.compile(
    r"\b(i|i'm|im|i've|ive|my|me|we|he|she|they|him|her|someone|somebody|mom|mum|mother|father|dad|"
    r"baby|child|son|daughter|friend|husband|wife|brother|sister)\b"
)
_GENERAL_QUESTION = re.compile(
    r"^(?:what (?:is|are|does)|what's|explain|define|describe|tell me about|meaning of)\b"
)
_CURRENT = re.compile(r"\b(?:now|currently|today|happening|just started)\b")
_CLAUSE = re.compile(r"[.!?;,\n]+|\b(?:but|however|and now)\b")
# Exempt a directly negated English symptom only, never a later clause.
_NEGATED = re.compile(
    r"\b(?:no|without|denies|denied|(?:do not|don't|does not|doesn't) have)\s+(?:any\s+)?$"
)


def _normalize(text: str) -> str:
    normalized = unicodedata.normalize("NFKC", text).casefold()
    normalized = "".join(char for char in normalized if unicodedata.category(char) != "Cf")
    return re.sub(r"[^\S\n]+", " ", normalized.replace("’", "'").replace("‘", "'")).strip()


def detect_emergency(text: str) -> str | None:
    """Recognize red-flag wording without sending the text away."""
    medical = False
    for clause in _CLAUSE.split(_normalize(text)):
        clause = clause.strip()
        if (_GENERAL_QUESTION.match(clause) and not _PERSON.search(clause)
                and not _CURRENT.search(clause) and not _SINHALA.search(clause)):
            continue
        if any(_normalize(phrase) in clause for phrase in _SINHALA_SELF_HARM) or _SELF_HARM.search(clause):
            return "self_harm"
        if any(_normalize(phrase) in clause for phrase in _SINHALA_MEDICAL) or any(
            not _NEGATED.search(clause[:match.start()]) for match in _MEDICAL.finditer(clause)
        ):
            medical = True
    return "medical" if medical else None


def logged_emergency(rows: list[dict]) -> tuple[str, str] | None:
    """Prioritize a self-harm alert when multiple current symptom logs match."""
    medical = None
    for row in rows:
        text = row.get("name")
        if row.get("status") != "active" or not isinstance(text, str):
            continue
        kind = detect_emergency(text)
        if kind == "self_harm":
            return kind, text
        if kind == "medical" and medical is None:
            medical = kind, text
    return medical


def emergency_reply(kind: str, *, text: str = "") -> str:
    if _SINHALA.search(text):
        if kind == "self_harm":
            return (
                "ඔබට දැන්ම ඔබටම හානි කරගන්න ඉඩක් තිබේ නම් හෝ දැනටමත් හානියක් සිදුවී ඇත්නම්, 1990 අමතන්න. "
                "විශ්වාස කරන කෙනෙකුට දැන්ම කියන්න. ඔබ ළඟ රැඳී සිටින්න කියා ඔවුන්ගෙන් ඉල්ලන්න. "
                "මානසික සෞඛ්‍ය සහාය සඳහා 1926 අමතන්න."
            )
        return (
            "මෙය හදිසි තත්ත්වයක් විය හැකියි. දැන්ම 1990 සුව සැරිය ගිලන් රථ සේවාව අමතන්න. "
            "ඇමතුමට පිළිතුරු දෙන නිලධාරියාගේ උපදෙස් අනුගමනය කරන්න."
        )
    if kind == "self_harm":
        return (
            "You do not have to face this alone.\n\n"
            "- If there is immediate danger or someone may already have taken something or hurt themselves, "
            "call 1990 for an ambulance now. Ask someone you trust to stay nearby.\n"
            "- For mental health support, call or text 1926 (National Mental Health Helpline)."
        )
    return (
        "This could be an emergency. Please do not wait for the app.\n\n"
        "- Call 1990 (free ambulance, Suwa Seriya) now and follow the operator's instructions.\n\n"
        "You can also open the SOS screen in NOVA Health to alert your emergency contacts."
    )


# ---------------------------------------------------------------- output guard
_BLOCKED = re.compile(
    r"\b(?:you (?:definitely |certainly )?have been diagnosed|you are diagnosed|"
    r"you (?:definitely|certainly) have|you are suffering from|i diagnose|this is definitely|"
    r"you have (?:diabetes|asthma|cancer|pneumonia|hypertension|an infection)|"
    r"(?:stop|skip|restart|start|increase|reduce|decrease|double|halve|change|adjust) "
    r"(?:(?:taking|using) )?(?:(?:your|the|this|that|a|an) )?"
    r"(?:next |usual |daily )?(?:dose|medicine|medication|tablets?|pills?|insulin|antibiotics?)|"
    r"take (?:more of|another|an extra|it (?:after|before|with|without) (?:food|water))|"
    r"(?:take|give|use|try|start|swallow|inject)\s+(?:\w+\s+){0,4}"
    r"\d+(?:[.,]\d+)?\s*(?:mg|mcg|g|ml|tablets?|capsules?|pills?|units?)|"
    r"(?:take|give|use|try|start)\s+(?:(?:one|two|three|four|half)\s+(?:tablets?|capsules?|pills?)|"
    r"(?:paracetamol|acetaminophen|panadol|ibuprofen|aspirin|insulin|antibiotics?))|"
    r"(?:safe (?:for you|to (?:take|combine|mix))|no (?:known )?(?:drug )?interactions|"
    r"your (?:medicine|medication)s? (?:is|are) (?:completely )?(?:safe|fine))|"
    r"(?:no need to|do not|don't(?: need to)?) (?:call (?:an ambulance|emergency services|1990)|seek (?:urgent|emergency) help))\b"
)
_BLOCKED_SINHALA = ("මාත්‍රාව දෙගුණ", "මාත්‍රාව වැඩි කරන්න", "බෙහෙත් නවත්වන්න", "ඔබට අනිවාර්යයෙන්ම")
SAFETY_UNAVAILABLE = {
    "severity": "caution",
    "message": "Medication safety details could not be checked. Ask a pharmacist or doctor to review them.",
}
_SAFE_FALLBACK = (
    "I can't tell you what condition this is or change your treatment. Please talk to a doctor or "
    "pharmacist about it, and get medical help quickly if you feel very unwell."
)

_MED_WORDS = re.compile(
    r"\b(medicine|medicines|medication|medications|pill|pills|tablet|tablets|capsule|dose|doses|drug|"
    r"drugs|allerg\w*|antibiotic\w*|painkiller\w*|prescription)\b",
    re.I,
)


_PERSONAL_TREATMENT = re.compile(
    r"\b(?:(?:can|should|may|could) (?:i|we|my \w+) "
    r"(?:take|stop|start|skip|increase|decrease|combine|mix)\s+(?!a (?:nap|walk|break)\b)|"
    r"how (?:much|many|often) (?:\w+ ){0,4}(?:should|can) i (?:take|give)\b)"
)


def guard_output(text: str, *, question: str = "", limit: int | None = MAX_REPLY_CHARS) -> str:
    t = text.strip()
    normalized = re.sub(r"\s+", " ", _normalize(t))
    normalized = re.sub(r"[*_#`]", "", normalized)
    personal_medication = _MED_WORDS.search(question + " " + text) and _PERSONAL_TREATMENT.search(_normalize(question))
    if (not t or personal_medication or _BLOCKED.search(normalized)
            or any(_normalize(phrase) in normalized for phrase in _BLOCKED_SINHALA)):
        return _SAFE_FALLBACK
    if limit is not None and len(t) > limit:
        t = t[:limit].rsplit(" ", 1)[0] + "…"
    return t


def finalize(text: str, notes: list[dict]) -> str:
    """Attach the same fixed warnings and disclaimer to patient-facing text."""
    if notes:
        lines = [f"- {guard_output(note['message'], limit=None)}" for note in notes[:3]]
        text += "\n\nSafety notes:\n" + "\n".join(lines)
    return f"{text}\n\n{DISCLAIMER}"


def relevant_notes(notes: list[dict], question: str, answer: str) -> list[dict]:
    content = _normalize(question + " " + answer)
    if _MED_WORDS.search(content) or any(
        _normalize(word) in content for word in ("බෙහෙත්", "ඖෂධ", "මාත්‍රා")
    ):
        return notes
    return [note for note in notes if note.get("subject") and _normalize(note["subject"]) in content]
