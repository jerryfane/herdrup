#!/usr/bin/env python3
"""Analyses readiness-experiment-results.csv through the PREREGISTERED rule.

The decision is computed by importing flat() from check-decision-rule.py — the
same executable rule the document declares canonical — so the analysis cannot
quietly drift from the rule it claims to apply. Cutoffs were committed before
the run.

Reports observational quantities only. The selector neither estimates a
treatment effect nor quantifies uncertainty; the retained raw samples permit a
separate randomised-contrast analysis, which this script does not perform.
"""
import csv
import importlib.util
import math
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "checkrule", os.path.join(HERE, "check-decision-rule.py"))
rule = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rule)

def nearest_rank_p95(values):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(0.95 * len(ordered)) - 1)]


def main(path):
    rows = list(csv.DictReader(open(path)))

    # The rule is defined for complete arms of exactly TRIALS_PER_ARM — enforce
    # the preregistered dataset shape before computing anything. A truncated CSV
    # previously produced n=99 and an unqualified decision; a three-trial smoke
    # printed a decision too. Shape violations get no numbers at all.
    problems = []
    sequences = [r["sequence"] for r in rows]
    if len(set(sequences)) != len(sequences):
        problems.append("duplicate sequence numbers")
    if len(rows) != 3 * rule.TRIALS_PER_ARM:
        problems.append(f"{len(rows)} rows, expected {3 * rule.TRIALS_PER_ARM}")
    unknown = sorted({r["arm"] for r in rows} - {"A", "B", "C"})
    if unknown:
        problems.append(f"unknown arms {unknown}")
    for arm in ("A", "B", "C"):
        count = sum(1 for r in rows if r["arm"] == arm)
        if count != rule.TRIALS_PER_ARM:
            problems.append(f"arm {arm} has {count} rows, expected {rule.TRIALS_PER_ARM}")
    expected_sequences = {str(i) for i in range(3 * rule.TRIALS_PER_ARM)}
    if set(sequences) != expected_sequences and len(rows) == 3 * rule.TRIALS_PER_ARM:
        problems.append("sequence numbers are not exactly 0..299")
    for r in rows:
        if r["error"]:
            continue
        # Numeric VALIDITY, not just presence: a nan in one t_request survived
        # the presence check, propagated to max=nan, and still produced an
        # unqualified decision with exit 0. Every timing must parse finite and
        # non-negative or the dataset is malformed.
        for field in ("t_request_ms", "t_ready_ms", "session_age_ms", "started_at_ms"):
            raw = r[field]
            if not raw:
                if field == "t_ready_ms" and r["arm"] == "A":
                    continue
                problems.append(f"row {r['sequence']} lacks {field}")
                break
            try:
                value = float(raw)
            except ValueError:
                problems.append(f"row {r['sequence']} {field}={raw!r} does not parse")
                break
            if not math.isfinite(value) or value < 0:
                problems.append(f"row {r['sequence']} {field}={raw} is not finite and non-negative")
                break
        else:
            continue
        break
    if problems:
        for problem in problems:
            print(f"DATASET SHAPE VIOLATION: {problem}")
        print("the preregistered rule is defined for complete arms only — NO DECISION")
        return 1

    arms = {}
    for arm in ("A", "B", "C"):
        mine = [r for r in rows if r["arm"] == arm]
        ok = [r for r in mine if not r["error"]]
        errs = [r for r in mine if r["error"]]
        t_request = [float(r["t_request_ms"]) for r in ok]
        t_ready = [float(r["t_ready_ms"]) for r in ok if r["t_ready_ms"]]
        arms[arm] = {
            "n": len(mine), "ok": len(ok), "errors": len(errs),
            "error_kinds": sorted({r["error"] for r in errs}),
            "p95": nearest_rank_p95(t_request) if t_request else None,
            "median": statistics.median(t_request) if t_request else None,
            "max": max(t_request) if t_request else None,
            "outliers": sum(1 for v in t_request if v > rule.OUTLIER_MS),
            "t_ready_p95": nearest_rank_p95(t_ready) if t_ready else None,
            "t_ready_median": statistics.median(t_ready) if t_ready else None,
            "t_ready_max": max(t_ready) if t_ready else None,
            "t_ready_n": len(t_ready),
        }

    print(f"raw file: {path}  ({len(rows)} rows)")
    print(f"cutoffs (preregistered): margin={rule.MARGIN}ms  outlier>{rule.OUTLIER_MS:.0f}ms  "
          f"tail tolerance=+{rule.TAIL_TOLERANCE}  t_ready cap={rule.READY_CAP}ms")
    print()
    for arm, s in arms.items():
        print(f"arm {arm}: n={s['n']} ok={s['ok']} errors={s['errors']} {s['error_kinds'] or ''}")
        if s["p95"] is not None:
            print(f"        t_request p95={s['p95']:.2f}ms  median={s['median']:.2f}ms  "
                  f"max={s['max']:.2f}ms  outliers(>{rule.OUTLIER_MS:.0f}ms)={s['outliers']}")
        if arm in ("B", "C") and s["t_ready_p95"] is not None:
            print(f"        t_ready p95={s['t_ready_p95']:.2f}ms  "
                  f"median={s['t_ready_median']:.2f}ms  max={s['t_ready_max']:.2f}ms")

    # Connection accounting — exact treatment accounting, NOT a reuse ratio:
    # this design is mechanically one request per session, so it cannot measure
    # the insertion-to-checkout denominator a pool would have.
    print()
    print("herdr connections (treatment accounting): "
          f"A={arms['A']['n']}  B={arms['B']['n']}  C={2 * arms['C']['n']} "
          "(one sacrificial + one request per C trial)")

    # Fail closed, both ways. Error rows are retained in the CSV but excluded
    # from every statistic, so a decision over a censored arm would rest on
    # numbers the tail obligation exists to protect — and a missing t_ready
    # column previously defaulted to 0.0, which passed the 50 ms cap VACUOUSLY
    # and could have adopted C with zero evidence. Neither gets a decision.
    for arm, s in arms.items():
        if s["errors"] > 0:
            print(f"arm {arm} has {s['errors']} error row(s); the preregistered rule "
                  "covers complete arms only — NO DECISION. Rerun, or analyse the "
                  "errors before trusting anything here.")
            return 1
        if s["p95"] is None:
            print(f"arm {arm} has no successful samples; no decision is computable")
            return 1
    if arms["C"]["t_ready_n"] < arms["C"]["ok"]:
        print(f"arm C retained {arms['C']['t_ready_n']} t_ready values for "
              f"{arms['C']['ok']} trials; the replenishment cap cannot be evaluated — NO DECISION.")
        return 1

    outcome = rule.flat(
        arms["A"]["p95"], arms["B"]["p95"], arms["C"]["p95"],
        arms["A"]["outliers"], arms["B"]["outliers"], arms["C"]["outliers"],
        arms["C"]["t_ready_p95"],
    )
    print()
    print(f"decision (preregistered flat rule): {sorted(outcome)}")
    b_ready = arms["B"]["t_ready_p95"] or 0.0
    c_ready = arms["C"]["t_ready_p95"] or 0.0
    print(f"sensitivity — replenishment cap applied to BOTH arms (not the preregistered rule): "
          f"B t_ready p95={b_ready:.2f}ms, C={c_ready:.2f}ms vs cap {rule.READY_CAP}ms -> "
          f"{'neither qualifies' if b_ready > rule.READY_CAP and c_ready > rule.READY_CAP else 'differs from preregistered outcome' if (b_ready > rule.READY_CAP) != (c_ready > rule.READY_CAP) else 'same outcome'}")
    if len(outcome) != 1:
        print("ERROR: the rule returned multiple outcomes; the enumeration guarantee is broken")
        return 1

    # Post-hoc descriptive extras the Results section cites. The 90 ms cutoff is
    # NOT preregistered — it was chosen after seeing the data and is labelled as
    # such wherever reported; it feeds no decision.
    print()
    print("descriptive (post-hoc, no decision weight):")
    total = len(rows)
    span = max(float(r["started_at_ms"]) for r in rows) / 1000
    print(f"  run span: {span:.1f}s")
    for r in rows:
        if not r["error"] and float(r["t_request_ms"]) > rule.OUTLIER_MS:
            print(f"  outlier row: seq={r['sequence']} arm={r['arm']} t_request={float(r['t_request_ms']):.1f}ms")
    for arm, s in arms.items():
        mine = [r for r in rows if r["arm"] == arm and not r["error"]]
        tr = [float(r["t_request_ms"]) for r in mine]
        starts = [float(r["started_at_ms"]) for r in mine]
        quarters = [0, 0, 0, 0]
        for r in mine:
            quarters[min(3, int(r["sequence"]) * 4 // total)] += 1
        half = statistics.median(float(r["sequence"]) for r in rows)
        early = [float(r["t_request_ms"]) for r in mine if float(r["sequence"]) <= half]
        late = [float(r["t_request_ms"]) for r in mine if float(r["sequence"]) > half]
        slow = sorted(v for v in tr if v > 90)
        in_band = [v for v in slow if 100.0 <= v <= 102.0]
        print(f"  {arm}: >90ms={len(slow)}/{len(tr)}  "
              f"slow-range=[{slow[0]:.1f}..{slow[-1]:.1f}]ms  "
              f"in 100-102ms band: {len(in_band)}/{len(slow)}  "
              f"mean_start={sum(starts)/len(starts)/1000:.2f}s  quarters={quarters}  "
              f"p95(early half)={nearest_rank_p95(early):.2f}ms  p95(late half)={nearest_rank_p95(late):.2f}ms")

    # Which condition each arm met or failed, for the record-the-blocker obligation.
    a, b, c = arms["A"], arms["B"], arms["C"]
    for name, s in (("B", b), ("C", c)):
        margin_met = (a["p95"] - s["p95"]) >= rule.MARGIN
        tail_ok = s["outliers"] <= a["outliers"] + rule.TAIL_TOLERANCE
        parts = [f"p95 margin {'met' if margin_met else 'NOT met'} "
                 f"(A95-{name}95 = {a['p95'] - s['p95']:.2f}ms vs {rule.MARGIN}ms)",
                 f"outlier count {'within' if tail_ok else 'beyond'} tolerance "
                 f"({s['outliers']} vs A's {a['outliers']}+{rule.TAIL_TOLERANCE})"]
        if name == "C":
            ready_ok = s["t_ready_p95"] <= rule.READY_CAP
            parts.append(f"t_ready p95 {'within' if ready_ok else 'beyond'} cap "
                         f"({s['t_ready_p95']:.2f}ms vs {rule.READY_CAP}ms)")
        print(f"  {name}: " + "; ".join(parts))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else
                  os.path.join(HERE, "readiness-experiment-results.csv")))
