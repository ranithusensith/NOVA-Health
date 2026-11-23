import rules


def names(ws):
    return [w.subject for w in ws]


def test_penicillin_family_allergy_is_flagged_high():
    ws = rules.check_allergy_conflicts(["Amoxicillin"], ["Penicillin"])
    assert len(ws) == 1
    assert ws[0].severity == "high"
    assert "penicillin" in ws[0].message.lower()
    assert "pharmacist" in ws[0].message


def test_direct_name_match():
    ws = rules.check_allergy_conflicts(["Penicillin V"], ["penicillin"])
    assert names(ws) == ["Penicillin V"]
    assert "you listed an allergy" in ws[0].message


def test_brand_names_are_understood():
    assert rules.check_allergy_conflicts(["Augmentin 625"], ["Penicillin"])
    assert rules.check_allergy_conflicts(["Septrin"], ["Sulfa drugs"])
    assert rules.check_allergy_conflicts(["Brufen 400"], ["Ibuprofen / NSAIDs"])


def test_aspirin_allergy_also_flags_other_nsaids():
    ws = rules.check_allergy_conflicts(["Diclofenac"], ["Aspirin"])
    assert ws and ws[0].severity == "high"


def test_no_false_alarm_for_unrelated_medicine():
    assert rules.check_allergy_conflicts(["Cetirizine"], ["Penicillin", "Peanuts"]) == []
    assert rules.check_allergy_conflicts(["Paracetamol"], ["Penicillin"]) == []


def test_word_boundaries_avoid_partial_matches():
    # "aspirin" must not be found inside an unrelated word
    assert rules.families_of("Aspirinex") == set()
    assert "nsaid" in rules.families_of("Aspirin 75 mg")


def test_nsaid_with_asthma_or_kidney_disease_is_a_caution():
    ws = rules.check_conditions(["Ibuprofen"], ["Asthma", "Diabetes"])
    assert len(ws) == 1 and ws[0].severity == "caution"
    assert "asthma" in ws[0].message
    assert rules.check_conditions(["Paracetamol"], ["Asthma"]) == []


def test_two_paracetamol_products_are_flagged():
    ws = rules.check_duplicates(["Panadol", "Paracetamol 500"])
    assert len(ws) == 1 and ws[0].severity == "caution"


def test_daily_paracetamol_limit():
    meds = [{"name": "Paracetamol", "dosage": "1 g", "times": ["06:00", "10:00", "14:00", "18:00", "22:00"]}]
    ws = rules.check_paracetamol_limit(meds)
    assert len(ws) == 1 and ws[0].severity == "high"
    ok = [{"name": "Paracetamol", "dosage": "500 mg", "times": ["08:00", "14:00", "20:00"]}]
    assert rules.check_paracetamol_limit(ok) == []


def test_parse_mg():
    assert rules.parse_mg("500 mg") == 500
    assert rules.parse_mg("1 g") == 1000
    assert rules.parse_mg("2.5mg") == 2.5
    assert rules.parse_mg("one tablet") is None
    assert rules.parse_mg(None) is None


def test_check_all_puts_high_before_caution():
    meds = [{"name": "Ibuprofen", "dosage": "400 mg", "times": ["08:00"]},
            {"name": "Amoxicillin", "dosage": "500 mg", "times": ["08:00"]}]
    ws = rules.check_all(meds, ["Penicillin"], ["Asthma"])
    assert ws[0].severity == "high"
    assert any(w.severity == "caution" for w in ws)
