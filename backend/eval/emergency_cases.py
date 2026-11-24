"""Synthetic emergency wording scenarios based on published safety guidance.

Emergency categories and recent transient stroke signs use the sources in
docs/SAFETY_DESIGN.md. The wording and expected branches are test fixtures.
Independent clinician and native-speaker review is pending.
"""

# (case ID, language, synthetic text, expected branch)
CONTEXT_CASES = [
    ("en-breathing-paraphrase", "en", "I am unable to get enough air", "medical"),
    ("en-current-with-trigger", "en", "I cannot breathe if I lie down", "medical"),
    ("en-live-quote", "en", 'My father just said “I can’t breathe”.', "medical"),
    ("en-present-quote", "en", 'My mother says "I can\'t breathe".', "medical"),
    ("en-current-after-negation", "en", "No chest pain but I can't breathe", "medical"),
    ("en-current-with-and", "en", "I have no chest pain and cannot breathe", "medical"),
    ("en-current-after-history", "en", "I had chest pain last year and now I can't breathe", "medical"),
    ("en-transient-stroke-sign", "en", "My speech was slurred ten minutes ago and it went away.", "medical"),
    ("en-current-self-harm", "en", "I'm thinking about hurting myself now", "self_harm"),
    ("en-direct-negation", "en", "I am not having chest pain", None),
    ("en-negated-list", "en", "I have no chest pain or shortness of breath", None),
    ("en-negated-self-harm", "en", "I was not suicidal", None),
    ("en-old-resolved", "en", "I had chest pain last year and recovered", None),
    ("en-hypothetical", "en", "What if I have chest pain?", None),
    ("en-quote-translation", "en", 'Translate "I cannot breathe" into Tamil.', None),
    ("en-quote-training", "en", 'In a film the character says "I can\'t breathe".', None),
    ("en-quote-alone", "en", '“I have chest pain”', None),
    ("si-breathing", "si", "මට හුස්ම ගැනීමට අපහසුයි", "medical"),
    ("si-chest", "si", "මගේ පපුව තද වෙලා", "medical"),
    ("si-current-after-negation", "si", "පපුවේ වේදනාව නැහැ, නමුත් හුස්ම ගන්න බැහැ", "medical"),
    ("si-current-self-harm", "si", "මට දැන් මැරෙන්න ඕන", "self_harm"),
    ("si-negated", "si", "මගේ පපුවේ වේදනාව නැහැ", None),
    ("si-historical", "si", "ගිය අවුරුද්දේ පපුවේ වේදනාව තිබුණා", None),
    ("si-hypothetical", "si", "පපුවේ වේදනාව ඇති වුණොත් මොකද කරන්නේ?", None),
    ("si-quote", "si", "“මට හුස්ම ගන්න බැහැ” කියන වාක්‍යය පරිවර්තනය කරන්න", None),
    ("ta-breathing", "ta", "எனக்கு மூச்சு விட முடியவில்லை", "medical"),
    ("ta-current-chest", "ta", "எனக்கு இப்போது நெஞ்சு வலி", "medical"),
    ("ta-current-after-negation", "ta", "மார்பு வலி இல்லை ஆனால் மூச்சு விட முடியவில்லை", "medical"),
    ("ta-current-self-harm", "ta", "எனக்கு இப்போது தற்கொலை செய்ய வேண்டும் போலிருக்கிறது", "self_harm"),
    ("ta-negated", "ta", "எனக்கு மார்பு வலி இல்லை", None),
    ("ta-negated-self-harm", "ta", "எனக்கு தற்கொலை எண்ணம் இல்லை", None),
    ("ta-historical", "ta", "கடந்த ஆண்டு எனக்கு நெஞ்சு வலி இருந்தது", None),
    ("ta-hypothetical", "ta", "நெஞ்சு வலி வந்தால் என்ன செய்வது?", None),
    ("ta-education", "ta", "மாரடைப்பின் அறிகுறிகள் என்ன?", None),
    ("ta-quote", "ta", "“எனக்கு மூச்சு விட முடியவில்லை” என்பதை மொழிபெயர்க்கவும்", None),
]
