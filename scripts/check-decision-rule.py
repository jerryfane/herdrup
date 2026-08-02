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
OUTLIER_MS = 500.0        # t_request above this is an outlier
TRIALS_PER_ARM = 100      # the rule is defined for complete arms of exactly this size
TAIL_TOLERANCE = 1   # preregistered operational cutoff, NOT an evidence threshold.
                     # n=100 does not justify THIS boundary (0 vs 2 is Fisher
                     # two-sided p~0.50). Whether n=100 would support some OTHER
                     # tail criterion is not asserted either way: that depends on a
                     # baseline rate, margin, alpha and power, none of which are
                     # defined. Fixed before the run so the choice cannot be made
                     # after seeing the numbers.


def flat(A, B, C, oa, ob, oc, ready_c):
    """Current rule: qualification per candidate, then an ordered selection.

    The tail condition is an OPERATIONAL CUTOFF, not an inference. Strict
    improvement rejects an arm that cleared every cutoff, against a zero-outlier
    baseline;
    a cutoff of zero vetoes on a single event. Neither +1 nor +2 is justified by
    n=100 — the cutoff exists to be decidable and fixed in advance, not to be
    defensible as evidence.
    """
    if A <= MARGIN:
        return {"neither"}
    qb = (A - B) >= MARGIN and ob <= oa + TAIL_TOLERANCE
    qc = (A - C) >= MARGIN and oc <= oa + TAIL_TOLERANCE and ready_c <= READY_CAP
    if not qb and not qc:
        return {"neither"}
    if qb and not qc:
        return {"B"}
    if qc and not qb:
        return {"C"}
    return {"C" if (B - C) >= MARGIN else "B"}


def flat_symmetric(A, B, C, oa, ob, oc, ready_c, ready_b):
    """The symmetric-cap reading: identical to flat() except the replenishment
    cap applies to BOTH candidates. Not the preregistered rule — it exists so
    the sensitivity the analyzer prints is a run of an ACTUAL selector with all
    qualification conditions and ordering, not an ad-hoc inequality. The first
    "sensitivity" compared only the two t_ready values against the cap, and on
    a dataset where B failed the request margin while C qualified it reported
    "differs" when both real rules select C.
    """
    if A <= MARGIN:
        return {"neither"}
    qb = (A - B) >= MARGIN and ob <= oa + TAIL_TOLERANCE and ready_b <= READY_CAP
    qc = (A - C) >= MARGIN and oc <= oa + TAIL_TOLERANCE and ready_c <= READY_CAP
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

    # Boundary cases, each a rule bug that shipped or was one edit away.
    boundaries = [
        # zero-outlier baseline must not reject an arm that cleared every cutoff
        ((100, 5, 5, 0, 0, 0, 10), "B", "zero-outlier baseline rejects an arm that cleared every cutoff"),
        # one extra outlier is inside the preregistered cutoff
        ((100, 5, 100, 0, 1, 0, 10), "B", "a single extra outlier vetoes the only p95-qualified arm"),
        # two extra is outside it
        ((100, 5, 100, 0, 2, 0, 10), "neither", "an outlier count beyond tolerance is accepted"),
        # tolerance applies against a non-zero baseline too
        ((100, 5, 100, 3, 4, 0, 10), "B", "tolerance does not apply against a non-zero baseline"),
        ((100, 5, 100, 3, 5, 0, 10), "neither", "an outlier count beyond tolerance is accepted (non-zero baseline)"),
        # replenishment cap still bites
        ((100, 100, 5, 0, 0, 0, 51), "neither", "replenishment cap does not reject a slow prewarm"),
    ]
    for case, want, message in boundaries:
        got = flat(*case)
        if got != {want}:
            failures.append(f"{message}: {case} gave {got}, expected {{{want}}}")

    # The symmetric selector's own boundaries, including the case that exposed
    # the ad-hoc sensitivity: B disqualified on the request margin while C
    # qualifies -> BOTH rules select C, so a sensitivity that only compares
    # t_ready values against the cap wrongly reports divergence.
    symmetric_boundaries = [
        ((100, 95, 5, 0, 0, 0, 10, 10), "C", "B fails margin, C qualifies under both rules"),
        ((100, 5, 5, 0, 0, 0, 10, 100), "C", "B's own t_ready beyond cap must disqualify B symmetrically"),
        ((100, 5, 5, 0, 0, 0, 100, 100), "neither", "both beyond cap must adopt neither"),
        ((100, 5, 5, 0, 0, 0, 10, 10), "B", "tie-break unchanged when both qualify"),
    ]
    for case, want, message in symmetric_boundaries:
        got = flat_symmetric(*case)
        if got != {want}:
            failures.append(f"symmetric: {message}: {case} gave {got}, expected {{{want}}}")
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
