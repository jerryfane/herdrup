#!/usr/bin/env python3
"""Enumerates the readiness decision rule in docs/transport-measurements.md.

Exists because "exhaustive and single-valued" was asserted about a rule that was
neither. It models the SUPERSEDED ordered-with-fallbacks form under every
defensible reading, and the CURRENT flat form; the check is that the current form
reaches exactly one outcome for every input.

Exits non-zero if the current rule is ambiguous anywhere, or if a historical
count drifts from what the document states. Run it after changing the rule, and
do not describe a rule as exhaustive without it.
"""
import itertools
import sys

MARGIN = 20
READY_CAP = 50


def flat(A, B, C, oa, ob, oc, ready_c):
    """Current rule: qualification per candidate, then an ordered selection.

    Tail is NON-REGRESSION (<=), not strict improvement: a zero-outlier baseline
    would otherwise reject a treatment that removed the delay entirely.
    """
    if A <= MARGIN:
        return {"neither"}
    qb = (A - B) >= MARGIN and ob <= oa
    qc = (A - C) >= MARGIN and oc <= oa and ready_c <= READY_CAP
    if not qb and not qc:
        return {"neither"}
    if qb and not qc:
        return {"B"}
    if qc and not qb:
        return {"C"}
    return {"C" if (B - C) >= MARGIN else "B"}


def superseded(A, B, C, oa, ob, oc, ready_c):
    """The ordered form with vetoes written as fallback steps.

    Three readings, because the text did not say whether the vetoes re-applied to
    a fallback, nor whether a fallback continued through the remaining vetoes.
    """
    if A <= MARGIN:
        return {"neither"}
    beff, ceff = (A - B) >= MARGIN, (A - C) >= MARGIN
    if not beff and not ceff:
        return {"neither"}
    if beff and not ceff:
        sel = "B"
    elif ceff and not beff:
        sel = "C"
    else:
        sel = "C" if (B - C) >= MARGIN else "B"

    eff = {"B": beff, "C": ceff}
    rate = {"B": ob, "C": oc}
    out = set()

    if rate[sel] >= oa:                       # outlier veto fires
        other = "C" if sel == "B" else "B"
        # reading 1: fall back without re-checking anything
        out.add(other if eff[other] else "neither")
        # reading 2: fall back only if the other passes every condition
        ok = eff[other] and rate[other] < oa and (other != "C" or ready_c <= READY_CAP)
        out.add(other if ok else "neither")
        # reading 3: sequential — the fallback continues INTO the replenishment
        # veto, which reading 1 skipped by returning early.
        if eff[other]:
            if other == "C" and ready_c > READY_CAP:
                out.add("B" if beff else "neither")
            else:
                out.add(other)
        else:
            out.add("neither")
        return out

    if sel == "C" and ready_c > READY_CAP:    # replenishment veto fires
        out.add("B" if beff else "neither")
        out.add("B" if (beff and ob < oa) else "neither")
        return out

    return {sel}


def main():
    values = [5, 25, 50, 70, 80, 100]
    counts = [0, 1, 3]          # outlier counts out of n=100, not rates
    readies = [10, 50, 51, 200]

    total = flat_ambiguous = superseded_ambiguous = 0
    for A, B, C in itertools.product(values, repeat=3):
        for oa, ob, oc in itertools.product(counts, repeat=3):
            for ready in readies:
                total += 1
                if len(flat(A, B, C, oa, ob, oc, ready)) > 1:
                    flat_ambiguous += 1
                if len(superseded(A, B, C, oa, ob, oc, ready)) > 1:
                    superseded_ambiguous += 1

    print(f"{total} input combinations")
    print(f"superseded (3 readings): {superseded_ambiguous} ambiguous "
          f"({100 * superseded_ambiguous / total:.1f}%)")
    print(f"current flat rule:       {flat_ambiguous} ambiguous")

    failures = []
    if flat_ambiguous:
        failures.append(f"current rule is ambiguous on {flat_ambiguous} inputs")
    if superseded_ambiguous != 3072:
        failures.append(
            f"superseded ambiguity is {superseded_ambiguous}, not the 3072 the document states"
        )

    # The zero-outlier hole the strict-improvement version had, kept as a
    # regression case: a treatment that removes the delay entirely must be
    # adopted even when the baseline has no tail to improve on.
    if flat(100, 5, 5, 0, 0, 0, 10) != {"B"}:
        failures.append("a zero-outlier baseline still rejects a perfect treatment")
    # Both cases the ordered version resolved two ways.
    for case, want in ((100, 80, 80, 1, 0, 0, 10), "B"), ((100, 50, 70, 1, 0, 0, 10), "B"):
        got = flat(*case)
        if got != {want}:
            failures.append(f"case {case[:3]} gives {got}, expected {{{want}}}")

    for line in failures:
        print(f"FAIL: {line}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
