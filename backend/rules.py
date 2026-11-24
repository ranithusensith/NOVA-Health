"""
Medicine safety rules (knowledge-based reasoning). Fixed, explainable, no AI.

This is a small teaching rule base, NOT a full drug database. It catches common,
clear cases: allergy conflicts, cautions with some conditions, double paracetamol
and a daily paracetamol limit. Every message tells the user to ask a pharmacist.
"""

import re
from dataclasses import dataclass


@dataclass
class Warning:
    severity: str  # 'high' | 'caution'
    message: str
    subject: str = ""  # the medicine the note is about

    def as_dict(self) -> dict:
        return {"severity": self.severity, "message": self.message, "subject": self.subject}


# Medicine families (lowercase, generic and common Sri Lankan brand names).
FAMILIES: dict[str, set[str]] = {
    "penicillin": {
        "penicillin", "amoxicillin", "amoxycillin", "ampicillin", "cloxacillin", "flucloxacillin",
        "amoxiclav", "co-amoxiclav", "coamoxiclav", "augmentin", "piperacillin", "benzylpenicillin",
        "phenoxymethylpenicillin", "penicillin v",
    },
    "sulfa": {
        "sulfamethoxazole", "co-trimoxazole", "cotrimoxazole", "septrin", "bactrim", "sulfadiazine",
        "sulfasalazine", "sulphonamide", "sulfonamide",
    },
    "nsaid": {
        "ibuprofen", "diclofenac", "naproxen", "aspirin", "mefenamic acid", "mefenamic", "ketorolac",
        "indomethacin", "celecoxib", "etoricoxib", "piroxicam", "meloxicam", "brufen", "voltaren",
        "ponstan", "nurofen", "disprin",
    },
    "aspirin": {"aspirin", "acetylsalicylic acid", "disprin"},
    "paracetamol": {"paracetamol", "acetaminophen", "panadol", "calpol", "crocin"},
}

# What a user might type as an allergy -> which families it means.
ALLERGY_TO_FAMILIES = [
    (("penicillin",), ["penicillin"]),
    (("sulfa", "sulpha", "sulfon", "sulphon", "co-trimoxazole", "cotrimoxazole"), ["sulfa"]),
    (("nsaid", "ibuprofen", "diclofenac", "naproxen", "anti-inflammatory", "antiinflammatory"), ["nsaid"]),
    (("aspirin",), ["aspirin", "nsaid"]),  # aspirin allergy: also take care with other NSAIDs
    (("paracetamol", "acetaminophen"), ["paracetamol"]),
]

NSAID_CONDITIONS = {
    "asthma": "asthma",
    "kidney disease": "kidney disease",
    "heart disease": "heart disease",
    "high blood pressure": "high blood pressure",
}


def _norm(s: str) -> str:
    return re.sub(r"\s+", " ", s.lower()).strip()


def families_of(medicine: str) -> set[str]:
    m = _norm(medicine)
    found = set()
    for fam, names in FAMILIES.items():
        for n in names:
            if re.search(r"(?<![a-z])" + re.escape(n) + r"(?![a-z])", m):
                found.add(fam)
                break
    return found


def _allergy_families(allergy: str) -> set[str]:
    a = _norm(allergy)
    fams: set[str] = set()
    for keys, families in ALLERGY_TO_FAMILIES:
        if any(k in a for k in keys):
            fams.update(families)
    return fams


_MASS = r"([0-9]{1,5}(?:\.[0-9]{1,4})?)\s*(mg|g)"


def parse_mg(dosage: str | None) -> float | None:
    if not isinstance(dosage, str):
        return None
    match = re.fullmatch(_MASS, _norm(dosage))
    if not match:
        return None
    value = float(match[1]) * (1000 if match[2] == "g" else 1)
    return value if value > 0 else None


def _paracetamol_mg_per_dose(med: dict) -> float | None:
    dosage = med.get("dosage")
    if not isinstance(dosage, str):
        return None
    text = _norm(dosage)
    if text.endswith(" per dose"):
        return parse_mg(text.removesuffix(" per dose"))
    match = re.fullmatch(r"([1-9][0-9]?) tablets? (?:of |x )(" + _MASS + r")(?: each)?", text)
    if match and (strength := parse_mg(match[2])) is not None:
        return int(match[1]) * strength
    return None


def _doses_per_24h(plan: dict) -> int | None:
    if plan.get("kind") == "interval":
        minutes = plan.get("interval_minutes")
        if type(minutes) is int and 1 <= minutes <= 525600:
            return 1 + (24 * 60 - 1) // minutes
    if plan.get("kind") == "daily":
        frequency = plan.get("frequency")
        if isinstance(frequency, str):
            text = _norm(frequency)
            named = {"daily": 1, "once daily": 1, "twice daily": 2, "three times daily": 3,
                     "four times daily": 4}
            if text in named:
                return named[text]
            match = re.fullmatch(r"([1-9]|1[0-9]|2[0-4]) times? (?:daily|a day|per day)", text)
            if match:
                return int(match[1])
    return None


def check_allergy_conflicts(medicines: list[str], allergies: list[str]) -> list[Warning]:
    out: list[Warning] = []
    for med in medicines:
        med_fams = families_of(med)
        med_l = _norm(med)
        for allergy in allergies:
            al = _norm(allergy)
            if not al:
                continue
            direct = al in med_l or med_l in al
            shared = med_fams & _allergy_families(allergy)
            if direct or shared:
                fam = sorted(shared)[0] if shared else ""
                if direct:
                    why = f"you listed an allergy to {allergy}"
                    family_text = ""
                else:
                    why = f"it is related to your listed allergy to {allergy}"
                    family_text = f" ({fam} family)"
                out.append(Warning(
                    "high",
                    f"{med}{family_text}: {why}. Do not take it until a doctor or pharmacist has reviewed the allergy.",
                    med,
                ))
                break  # one warning per medicine is enough
    return out


def check_conditions(medicines: list[str], conditions: list[str]) -> list[Warning]:
    out: list[Warning] = []
    cond_l = [_norm(c) for c in conditions]
    for med in medicines:
        if "nsaid" not in families_of(med):
            continue
        hits = [label for key, label in NSAID_CONDITIONS.items() if any(key in c for c in cond_l)]
        if hits:
            out.append(Warning(
                "caution",
                f"{med}: this type of painkiller (NSAID) can be a problem with {', '.join(hits)}. "
                "Ask your doctor or pharmacist first.",
                med,
            ))
    return out


def check_duplicates(medicines: list[str]) -> list[Warning]:
    out: list[Warning] = []
    for fam, label in (("paracetamol", "paracetamol"), ("nsaid", "NSAID painkillers")):
        names = [m for m in medicines if fam in families_of(m)]
        if len(names) >= 2:
            out.append(Warning(
                "caution",
                f"You have more than one medicine with {label} ({', '.join(names)}). "
                "Taking them together can add up, so check with a pharmacist.",
                names[0],
            ))
    return out


def check_paracetamol_limit(meds: list[dict]) -> list[Warning]:
    """Estimate planned exposure from explicit amounts and prescription timing."""
    total = 0.0
    names: list[str] = []
    unknown: list[str] = []
    for med in meds:
        name = med.get("name")
        if not isinstance(name, str) or "paracetamol" not in families_of(name):
            continue
        plan = med.get("prescription_plan")
        per_day = _doses_per_24h(plan) if isinstance(plan, dict) else None
        # Strength alone does not say how many units a person takes. A product
        # with another known ingredient family also needs an ingredient review.
        single_ingredient = _norm(name) in FAMILIES["paracetamol"]
        mg = _paracetamol_mg_per_dose(med) if single_ingredient else None
        if isinstance(plan, dict) and plan.get("kind") == "daily" and med.get("times"):
            # Reviewed daily dose times and written frequency should agree.
            # They do not supply the frequency when the directions are unclear.
            if len(med["times"]) != per_day:
                per_day = None
        if mg is None or per_day is None:
            unknown.append(name)
            continue
        total += mg * per_day
        names.append(name)

    warnings = []
    if total > 4000:
        warnings.append(Warning(
            "high",
            f"The recorded schedules could add up to {total / 1000:g} g of paracetamol in 24 hours, "
            "above the general adult limit. Ask a pharmacist or doctor to review the prescription. "
            "If you may have taken too much, seek urgent medical help now.",
            names[0],
        ))
    if unknown:
        warnings.append(Warning(
            "caution",
            "The paracetamol total could not be checked for all recorded medicines. Ask a pharmacist "
            "to verify the ingredients, amount per dose and dosing instructions.",
            unknown[0],
        ))
    return warnings


def check_all(meds: list[dict], allergies: list[str], conditions: list[str]) -> list[Warning]:
    names = [name for m in meds if isinstance(name := m.get("name"), str) and name.strip()]
    results = (
        check_allergy_conflicts(names, allergies)
        + check_paracetamol_limit(meds)
        + check_conditions(names, conditions)
        + check_duplicates(names)
    )
    results.sort(key=lambda w: 0 if w.severity == "high" else 1)
    return results
