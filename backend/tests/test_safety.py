import safety


def test_emergency_medical():
    for text in ["I have chest pain", "he is not breathing", "I think I'm having a heart attack",
                 "my mother is unconscious", "I can't breathe properly"]:
        assert safety.detect_emergency(text) == "medical", text


def test_emergency_self_harm_takes_priority():
    assert safety.detect_emergency("I want to die") == "self_harm"
    assert safety.detect_emergency("chest pain and I want to end my life") == "self_harm"


def test_normal_questions_are_not_emergencies():
    for text in ["Why am I tired this week?", "How much water should I drink?", "Is my sleep okay?"]:
        assert safety.detect_emergency(text) is None


def test_emergency_replies_name_the_right_numbers():
    medical = safety.emergency_reply("medical")
    assert "1990" in medical
    harm = safety.emergency_reply("self_harm")
    assert "1926" in harm and "1990" in harm
    # Never give methods or judgement
    assert "pills" not in harm.lower()


def test_redact_removes_contact_details():
    text = "mail me at ana.perera@example.com or call +94 77 123 4567, NIC 199912345678"
    out = safety.redact(text)
    assert "@" not in out and "123 4567" not in out and "199912345678" not in out
    assert "[email]" in out and "[phone]" in out and "[id]" in out


def test_redact_keeps_normal_numbers():
    assert safety.redact("I slept 6 hours and drank 2 litres") == "I slept 6 hours and drank 2 litres"


def test_guard_blocks_diagnosis_wording():
    out = safety.guard_output("You definitely have diabetes.")
    assert "doctor or pharmacist" in out
    assert "diabetes" not in out.lower()


def test_guard_blocks_dose_changes():
    assert "doctor or pharmacist" in safety.guard_output("You should double your dose tonight.")


def test_guard_shortens_very_long_text():
    out = safety.guard_output("word " * 1000)
    assert len(out) <= safety.MAX_REPLY_CHARS + 2


def test_finalize_adds_disclaimer_and_notes_for_medicine_questions():
    notes = [{"severity": "high", "message": "Amoxicillin: do not take it.", "subject": "Amoxicillin"}]
    question = "Can I take my medicine with food?"
    answer = "Take it after food."
    out = safety.finalize(safety.guard_output(answer, question=question), safety.relevant_notes(notes, question, answer))
    assert "Safety notes" in out and "Amoxicillin" in out
    assert out.rstrip().endswith(safety.DISCLAIMER)


def test_finalize_skips_notes_for_unrelated_questions():
    notes = [{"severity": "high", "message": "Amoxicillin: do not take it.", "subject": "Amoxicillin"}]
    answer = "You slept 5 hours."
    out = safety.finalize(answer, safety.relevant_notes(notes, "How did I sleep?", answer))
    assert "Safety notes" not in out
    assert out.rstrip().endswith(safety.DISCLAIMER)


def test_verb_forms_of_self_harm_are_caught():
    for text in ["I'm thinking about ending my life", "I want to end it all", "I wish I was dead",
                 "thinking of taking my own life"]:
        assert safety.detect_emergency(text) == "self_harm", text


def test_definition_questions_are_not_emergencies():
    for text in ["What is stroke?", "Explain what a heart attack is", "what are the signs of a seizure",
                 "Define anaphylaxis"]:
        assert safety.detect_emergency(text) is None, text


def test_a_person_in_trouble_is_still_an_emergency_even_in_a_question():
    for text in ["What should I do? my mother is unconscious", "what is happening, I have chest pain",
                 "what do I do, he is not breathing"]:
        assert safety.detect_emergency(text) == "medical", text


def test_clinical_range_exception_does_not_apply_to_phone_fields_or_chat():
    assert safety.clinical_text("WBC reference 4000 - 11000") == "WBC reference 4000 - 11000"
    assert safety.clinical_text("WBC reference 4000-11000") == "WBC reference 4000-11000"
    assert safety.redact("4000 - 11000") == "[phone]"
    assert safety.clinical_text("Contact 4000 - 11000") == "Contact [phone]"
    assert safety.clinical_text("Phone: 4000 - 11000\nWBC reference 4000 - 11000") == "WBC reference 4000 - 11000"
    assert safety.clinical_text("Call office phone: 4000 - 11000") == "Call office [phone]"
