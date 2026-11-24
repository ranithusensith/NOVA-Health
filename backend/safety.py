"""
Safety layer around the AI. Fixed rules, never decided by the model.

1. redact()            removes emails, phone numbers and ID numbers before text reaches the AI
2. detect_emergency()  recognises red-flag messages BEFORE any AI call
3. guard_output()      blocks common unsafe treatment and diagnosis wording
4. finalize()          adds rule-engine safety notes and the disclaimer

Emergency detection uses a limited English, Sinhala, and Tamil vocabulary.
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
    r"(?:want to|wanna) die|suicid(?:e|al)|hurt(?:ing)? myself|self[ -]harm|don'?t want to live|"
    r"better off dead|ending my life|tak(?:e|ing) my own life|end(?:ing)? it all|"
    r"no reason to live|not worth living|wish i (?:was|were) dead)\b"
)
_MEDICAL = re.compile(
    r"\b(?:chest (?:pain|pressure|tightness|heaviness)|"
    r"(?:pain|pressure|tightness) in (?:my|the|his|her) chest|"
    r"(?:can'?t|cannot|can not) (?:breathe|catch (?:my|his|her) breath)|not breathing|gasping|"
    r"(?:trouble|difficulty) breathing|hard to breathe|struggling to breathe|"
    r"(?:unable to|can'?t|cannot) get enough air|unable to breathe|shortness of breath|"
    r"heart attack|stroke|fac(?:e|ial) (?:is )?droop(?:s|ing)?|slurred speech|speech (?:is|was) slurred|"
    r"one[ -]sided weakness|(?:can'?t|cannot) (?:move (?:one|my|his|her) arm|speak)|"
    r"unconscious|unresponsive|passed out|fainted|won'?t wake up|seizures?|convulsions?|"
    r"(?:severe|heavy) bleeding|bleeding (?:heavily|a lot|won'?t stop)|"
    r"(?:coughing(?: up)?|vomiting|throwing up) blood|choking|"
    r"overdos(?:e|ed)|(?:took|taken|swallowed) too (?:many|much)|swallowed poison|"
    r"poisoned|anaphylaxis|throat (?:is )?closing|tongue (?:is )?swelling|"
    r"swelling of my throat|severe allergic reaction)\b"
)
_SINHALA_SELF_HARM = (
    "මැරෙන්න ඕන", "ජීවිතේ නැති කරගන්න", "ජීවිතය නැති කරගන්න", "සියදිවි නසාගන්න", "සියදිවි නසා ගැනීමට",
)
_SINHALA_MEDICAL = (
    "පපුව රිදෙනවා", "පපුවේ වේදනාව", "පපුවේ කැක්කුම", "පපුව තද වෙනවා",
    "හුස්ම ගන්න බෑ", "හුස්ම ගන්න බැහැ", "හුස්ම ගන්න බැරි", "හුස්ම ගන්න අමාරු",
    "හුස්ම ගන්නේ නෑ", "හුස්ම ගන්නෙ නෑ", "හුස්ම ගන්නේ නැහැ", "හුස්ම හිර",
    "සිහිය නැහැ", "සිහිය නෑ", "සිහිය නැති", "ලේ ගොඩක් යනවා", "ලේ නවතින්නේ නැහැ",
    "ලේ වමනය", "විෂ බීලා", "බෙහෙත් වැඩිපුර ගත්තා", "බෙහෙත් ගොඩක් බිව්වා",
    "මූණ පැත්තකට වැටිලා", "වලිප්පුව හැදිලා",
    "හුස්ම ගැනීමට අපහසු", "හුස්ම ගැනීමේ අපහසුතාව", "පපුව තද වෙලා", "අතක් පණ නැහැ",
    "කතා කරන්න බැහැ", "දිව ඉදිමෙනවා", "සිහිය නැතිවුණා",
)
_SINHALA = re.compile(r"[\u0d80-\u0dff]")
_TAMIL = re.compile(r"[\u0b80-\u0bff]")
_TAMIL_SELF_HARM = (
    "தற்கொலை", "என்னைக் கொல்ல", "என்னை கொல்ல", "என்னை காயப்படுத்திக்கொள்ள",
    "என்னையே காயப்படுத்த", "சாக வேண்டும்", "வாழ விருப்பமில்லை", "உயிரை மாய்த்துக்கொள்ள",
)
_TAMIL_MEDICAL = (
    "மார்பு வலி", "மார்பில் வலி", "நெஞ்சு வலி", "நெஞ்சு வலிக்கிறது", "மார்பு இறுக்கம்",
    "மூச்சு விட முடியவில்லை", "மூச்சுவிட முடியவில்லை", "மூச்சு விடவில்லை",
    "மூச்சு விட சிரமம்", "மூச்சு விடுவதில் சிரமம்", "மூச்சுத்திணறல்", "மூச்சுத் திணறல்",
    "சுவாசிக்க முடியவில்லை", "சுவாசிக்க சிரமம்", "மயங்கி விழுந்த", "சுயநினைவு இல்லை",
    "இரத்தம் நிற்கவில்லை", "அதிக இரத்தப்போக்கு", "இரத்த வாந்தி", "ரத்த வாந்தி",
    "முகம் ஒரு பக்கம் சாய்ந்த", "பேச்சு குழற", "கை அசைக்க முடியவில்லை",
    "பேச முடியவில்லை", "வலிப்பு", "பக்கவாதம்", "மாரடைப்பு",
    "அதிகமாக மாத்திரை", "விஷம் குடித்த", "தொண்டை அடைக்கிறது", "நாக்கு வீங்குகிறது",
)
_PERSON = re.compile(
    r"\b(i|i'm|im|i've|ive|my|me|we|he|she|they|him|her|someone|somebody|mom|mum|mother|father|dad|"
    r"baby|child|son|daughter|friend|husband|wife|brother|sister)\b"
)
_GENERAL_QUESTION = re.compile(
    r"^(?:what (?:is|are|does)|what's|explain|define|describe|tell me about|meaning of|"
    r"translate|how do you say|give (?:me )?an example)\b"
    r"|යනු කුමක්ද|කියන්නේ මොකක්ද|ලක්ෂණ මොනවාද|පරිවර්තනය කරන්න"
    r"|என்றால் என்ன|அறிகுறிகள் என்ன|விளக்குங்கள்|மொழிபெயர்க்கவும்"
)
_CURRENT = re.compile(
    r"\b(?:now|currently|today|happening|still|this morning|just started|just happened|"
    r"(?:minutes? or hours?|minutes?|hours?) ago|last night)\b"
    r"|දැන්|තවම|අද|இப்போது|இப்பொழுது|தற்போது|இன்னும்|இன்று"
)
_CLAUSE = re.compile(
    r"[.!?;,:\n]+|\b(?:but|however|and now|and (?=(?:i|he|she|they|my|we)\b))\b"
    r"|නමුත්|ඒත්|ஆனால்|இருந்தாலும்"
)
_NONCURRENT = re.compile(
    r"\b(?:(?:family )?history of|used to|"
    r"last (?:week|month|year)|yesterday|(?:days?|weeks?|months?|years?) ago|"
    r"previously|in the past)\b"
    r"|ඊයේ|පසුගිය|කලින්|ගිය අවුරුද්දේ"
    r"|நேற்று|முன்பு|கடந்த (?:வாரம்|மாதம்|ஆண்டு)|வருடங்களுக்கு முன்"
)
_HYPOTHETICAL = re.compile(
    r"\b(?:if|suppose|hypothetically|imagine|in (?:a|the) (?:movie|film|book|story|scenario|example))\b"
)
_LOCAL_CONDITIONAL = re.compile(r"(?:වුණොත්|නම්|வந்தால்|ஏற்பட்டால்|இருந்தால்|முடியாவிட்டால்|என்றால்)(?=\s|$)")
_NEGATED_BEFORE = re.compile(
    r"\b(?:no|not|without|denies|denied|do not|don't|does not|doesn't|never had)"
    r"\s+(?:(?:have|having|feel|feeling|any|longer|been|currently)\s+)*$"
)
_NEGATED_LIST = re.compile(r"(?:or|nor)(?:\s+any)?")
_NEGATED_AFTER = re.compile(
    r"^(?:\s+(?:(?:is|are|has|have)\s+)?(?:gone|resolved|no longer present)\b"
    r"|\s*(?:නැහැ|නෑ|නොමැත|නැති වුණා|(?:எண்ணம்\s+)?இல்லை|கிடையாது|நின்றுவிட்டது))"
)
_RESOLVED = re.compile(r"^\s*(?:(?:and|but)\s+)?(?:it\s+)?(?:went away|got better|resolved|stopped now|has stopped)\b")
_STROKE_WORDING = re.compile(
    r"\bstroke\b|droop|slurred|one[ -]sided weakness|(?:move (?:one|my|his|her) arm|speak)"
    r"|මූණ පැත්තකට|අතක් පණ|කතා කරන්න|பக்கவாதம்|முகம் ஒரு பக்கம்|பேச்சு குழற|கை அசைக்க|பேச முடிய"
)
_QUOTED = re.compile(r'"[^"\n]+"|“[^”\n]+”|‘[^’\n]+’|(?<!\w)\x27[^\n]+?\x27(?!\w)')
_REPORTED_SPEECH = re.compile(
    r"\b(?:said|says|told me|texted|messaged|shouted|heard)\b|කිව්වා|කියනවා|சொன்னார்|சொல்கிறார்"
)
_LIVE_SPEECH = re.compile(r"\b(?:is saying|says|just said|just texted)\b|කියනවා|சொல்கிறார்")
_PERSONAL_CURRENT = re.compile(r"\b(?:i|me|my|we)\b|මට|මගේ|எனக்கு|என்")
_QUOTED_EXAMPLE = re.compile(r"\b(?:character|poster|subtitle|lyrics|script|example|translate|phrase)\b")


def _normalize(text: str) -> str:
    normalized = unicodedata.normalize("NFKC", text).casefold()
    normalized = "".join(char for char in normalized if unicodedata.category(char) != "Cf")
    return re.sub(r"[^\S\n]+", " ", normalized.replace("’", "'").replace("‘", "'")).strip()


def _literal_matches(clause: str, phrases):
    for phrase in phrases:
        yield from re.finditer(re.escape(phrase), clause)


def _has_current_match(clause: str, matches, *, current: bool) -> bool:
    negated = False
    end = 0
    hypothetical = _HYPOTHETICAL.search(clause)
    for match in sorted(matches, key=lambda item: (item.start(), -item.end())):
        # A conditional after an asserted symptom does not cancel that symptom.
        if hypothetical and hypothetical.start() < match.start():
            break
        if match.start() < end:
            continue
        prefix = clause[end:match.start()]
        matched = match.group()
        end = match.end()
        suffix = clause[end:]
        negated = bool(_NEGATED_BEFORE.search(prefix) or (negated and _NEGATED_LIST.fullmatch(prefix.strip())))
        if negated:
            continue
        # A recently resolved stroke-like statement still needs urgent evaluation.
        if (_NEGATED_AFTER.match(suffix) or _RESOLVED.search(suffix)) and not (
            current and _STROKE_WORDING.search(matched)
        ):
            negated = True
            continue
        return True
    return False


def _without_quoted_examples(text: str) -> str:
    def replace(match):
        before = re.split(r"[.!?;\n]", text[:match.start()])[-1]
        after = re.split(r"[.!?;\n]", text[match.end():], maxsplit=1)[0]
        context = _normalize(before + " " + after)
        current_report = _CURRENT.search(context) and (
            _REPORTED_SPEECH.search(context) or _PERSONAL_CURRENT.search(context)
        )
        live_report = (_LIVE_SPEECH.search(context) and (_PERSON.search(context) or _PERSONAL_CURRENT.search(context))
                       and not _NONCURRENT.search(context))
        if (current_report or live_report) and not (_HYPOTHETICAL.search(context) or _QUOTED_EXAMPLE.search(context)):
            return match.group()[1:-1]
        return " "

    return _QUOTED.sub(replace, unicodedata.normalize("NFKC", text))


def detect_emergency(text: str) -> str | None:
    """Recognize red-flag wording without sending the text away."""
    medical = False
    for clause in _CLAUSE.split(_normalize(_without_quoted_examples(text))):
        clause = clause.strip()
        current = bool(_CURRENT.search(clause))
        if _LOCAL_CONDITIONAL.search(clause) or (_NONCURRENT.search(clause) and not current):
            continue
        if (_GENERAL_QUESTION.match(clause) and not _PERSON.search(clause)
                and not current):
            continue
        harm = [*_SELF_HARM.finditer(clause), *_literal_matches(clause, _SINHALA_SELF_HARM + _TAMIL_SELF_HARM)]
        if _has_current_match(clause, harm, current=current):
            return "self_harm"
        signs = [*_MEDICAL.finditer(clause), *_literal_matches(clause, _SINHALA_MEDICAL + _TAMIL_MEDICAL)]
        if _has_current_match(clause, signs, current=current):
            medical = True
    return "medical" if medical else None


def _tamil_response(text: str) -> bool:
    return len(_TAMIL.findall(text)) > len(_SINHALA.findall(text))


def saved_emergency_reply(kind: str, *, text: str) -> str:
    if _tamil_response(text):
        intro = "சமீபத்திய அறிகுறிப் பதிவு செயலில் உள்ளது. அறிகுறி இப்போதும் உள்ளதா என்பதை NOVA உறுதி செய்ய முடியாது."
        action = "இது அவசரமாக இருக்கலாம் என்று தோன்றினால் அல்லது உறுதியாகத் தெரியாவிட்டால், இலங்கையில் 1990 ஐ இப்போதே அழையுங்கள்."
    elif _SINHALA.search(text):
        intro = "මෑත රෝග ලක්ෂණ සටහනක් තවමත් සක්‍රියයි. එම ලක්ෂණය දැන් තිබේදැයි NOVA හට තහවුරු කළ නොහැක."
        action = "මෙය හදිසි තත්ත්වයක් විය හැකි නම් හෝ ඒ ගැන සැකයක් ඇත්නම්, ශ්‍රී ලංකාවේ දැන්ම 1990 අමතන්න."
    else:
        intro = "A recent symptom entry is still marked active. NOVA cannot confirm whether the symptom is present now."
        action = "If this could be an emergency or you are unsure, call 1990 in Sri Lanka now."
    if kind == "self_harm":
        action = emergency_reply(kind, text=text)
    return f"{intro}\n\n{action}"


def emergency_reply(kind: str, *, text: str = "") -> str:
    if _tamil_response(text):
        if kind == "self_harm":
            return (
                "உங்களுக்கு உடனடி ஆபத்து இருந்தால் அல்லது ஏற்கனவே காயம் ஏற்பட்டிருந்தால், "
                "இலங்கையில் 1990 ஆம்புலன்ஸ் சேவையை இப்போதே அழையுங்கள். "
                "நீங்கள் நம்பும் ஒருவரிடம் சொல்லி, உங்களுடன் இருக்குமாறு கேளுங்கள். "
                "மனநல உதவிக்கு 1926 ஐ அழையுங்கள்."
            )
        return (
            "இது அவசர நிலையாக இருக்கலாம். செயலிக்காகக் காத்திருக்க வேண்டாம். "
            "இலங்கையில் 1990 சுவசெரிய ஆம்புலன்ஸ் சேவையை இப்போதே அழையுங்கள். "
            "அழைப்பை ஏற்கும் அலுவலரின் வழிமுறைகளைப் பின்பற்றுங்கள்."
        )
    if _SINHALA.search(text):
        if kind == "self_harm":
            return (
                "ඔබට දැන්ම ඔබටම හානි කරගන්න ඉඩක් තිබේ නම් හෝ දැනටමත් හානියක් සිදුවී ඇත්නම්, ශ්‍රී ලංකාවේ 1990 අමතන්න. "
                "විශ්වාස කරන කෙනෙකුට දැන්ම කියන්න. ඔබ ළඟ රැඳී සිටින්න කියා ඔවුන්ගෙන් ඉල්ලන්න. "
                "මානසික සෞඛ්‍ය සහාය සඳහා 1926 අමතන්න."
            )
        return (
            "මෙය හදිසි තත්ත්වයක් විය හැකියි. ශ්‍රී ලංකාවේ දැන්ම 1990 සුව සැරිය ගිලන් රථ සේවාව අමතන්න. "
            "ඇමතුමට පිළිතුරු දෙන නිලධාරියාගේ උපදෙස් අනුගමනය කරන්න."
        )
    if kind == "self_harm":
        return (
            "You do not have to face this alone.\n\n"
            "- If there is immediate danger or someone may already have taken something or hurt themselves, "
            "call 1990 for an ambulance in Sri Lanka now. Ask someone you trust to stay nearby.\n"
            "- For mental health support in Sri Lanka, call 1926 (National Mental Health Helpline)."
        )
    return (
        "This could be an emergency. Please do not wait for the app.\n\n"
        "- In Sri Lanka, call 1990 (Suwa Seriya ambulance) now and follow the operator's instructions.\n\n"
        "You can also open the SOS screen in NOVA Health to alert your emergency contacts."
    )


# ---------------------------------------------------------------- output guard
_BLOCKED = re.compile(
    r"\b(?:you (?:definitely |certainly )?have been diagnosed|you are diagnosed|"
    r"you (?:definitely|certainly) have|you are suffering from|i diagnose|this is definitely|"
    r"you have (?:diabetes|asthma|cancer|pneumonia|hypertension|an infection)|"
    r"you (?:probably|likely|most likely) have|you might have (?:diabetes|asthma|cancer|pneumonia|a stroke)|"
    r"(?:your (?:tests?|readings?|results?)|this (?:test|result|reading)) (?:prove[sd]?|confirm[s]?) "
    r"(?:that )?(?:nothing is wrong|you are fine|you have)|"
    r"(?:nothing to worry about|nothing (?:serious|is wrong)|you are definitely fine|you can safely wait)|"
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
_BLOCKED_LOCAL = (
    "මාත්‍රාව දෙගුණ", "මාත්‍රාව වැඩි කරන්න", "බෙහෙත් නවත්වන්න", "ඔබට අනිවාර්යයෙන්ම",
    "බය වෙන්න දෙයක් නැහැ", "ගිලන් රථයක් අවශ්‍ය නැහැ",
    "மருந்தின் அளவை இரட்டிப்பாக்க", "மருந்தை நிறுத்துங்கள்", "மருந்தின் அளவை அதிகரிக்க",
    "கவலைப்படத் தேவையில்லை", "ஆம்புலன்ஸ் தேவையில்லை", "உங்களுக்கு நிச்சயமாக",
)
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
            or any(_normalize(phrase) in normalized for phrase in _BLOCKED_LOCAL)):
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
