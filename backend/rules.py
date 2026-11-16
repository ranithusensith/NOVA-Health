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


def parse_mg(dosage: str | None) -> float | None:
    if not dosage:
        return None
    m = re.search(r"(\d+(?:\.\d+)?)\s*(mg|g)\b", dosage.lower())
    if not m:
        return None
    value = float(m.group(1))
    return value * 1000 if m.group(2) == "g" else value


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
                    f"{med}{family_text}: {why}. Do not take it until a doctor or pharmacist confirms it is safe for you.",
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
    """meds: [{'name','dosage','times':[...]}]. Assumes one unit per time."""
    total = 0.0
    names: list[str] = []
    for m in meds:
        if "paracetamol" not in families_of(m.get("name", "")):
            continue
        mg = parse_mg(m.get("dosage"))
        per_day = len(m.get("times") or [])
        if mg and per_day:
            total += mg * per_day
            names.append(m.get("name", "paracetamol"))
    if total > 4000:
        return [Warning(
            "high",
            f"Your paracetamol adds up to about {total / 1000:.1f} g a day. More than 4 g a day can damage "
            "the liver. Talk to a pharmacist or doctor today.",
            names[0],
        )]
    return []


def check_all(meds: list[dict], allergies: list[str], conditions: list[str]) -> list[Warning]:
    names = [m.get("name", "") for m in meds if m.get("name")]
    results = (
        check_allergy_conflicts(names, allergies)
        + check_paracetamol_limit(meds)
        + check_conditions(names, conditions)
        + check_duplicates(names)
    )
    results.sort(key=lambda w: 0 if w.severity == "high" else 1)
    return results
