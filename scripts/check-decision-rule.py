#!/usr/bin/env python3
"""Enumerates the readiness decision rule in docs/transport-measurements.md.

Exists because "exhaustive and single-valued" was asserted about a rule that was
neither. `published` models the superseded fallback form, `flat` the current one;
the check is that every input reaches exactly one outcome. Run it after changing
the rule, and do not describe a rule as exhaustive without it.
"""
import itertools

def published(A,B,C,oa,ob,oc,ready_c):
    if A <= 20: return {"neither"}
    beff, ceff = (A-B)>=20, (A-C)>=20
    if not beff and not ceff: return {"neither"}
    if beff and not ceff: sel="B"
    elif ceff and not beff: sel="C"
    else: sel = "C" if (B-C)>=20 else "B"
    out=set()
    orate = {"B":ob,"C":oc}[sel]
    if orate >= oa:
        other = "C" if sel=="B" else "B"
        othereff = ceff if other=="C" else beff
        # reading 1: fall back without re-checking vetoes
        out.add(other if othereff else "neither")
        # reading 2: fall back only if the other also passes its vetoes
        orate2 = {"B":ob,"C":oc}[other]
        ok = othereff and orate2 < oa and (other!="C" or ready_c<=50)
        out.add(other if ok else "neither")
        return out
    if sel=="C" and ready_c>50:
        out.add("B" if beff else "neither")          # reading 1
        out.add("B" if (beff and ob<oa) else "neither")  # reading 2
        return out
    return {sel}

def flat(A,B,C,oa,ob,oc,ready_c):
    if A <= 20: return {"neither"}
    q = {}
    q["B"] = (A-B)>=20 and ob<oa
    q["C"] = (A-C)>=20 and oc<oa and ready_c<=50
    if not q["B"] and not q["C"]: return {"neither"}
    if q["B"] and not q["C"]: return {"B"}
    if q["C"] and not q["B"]: return {"C"}
    return {"C" if (B-C)>=20 else "B"}

vals=[5,25,50,70,80,100]; orates=[0.0,0.05,0.10]; readies=[10,50,51,200]
amb_pub=amb_flat=total=0
for A,B,C in itertools.product(vals,repeat=3):
    for oa,ob,oc in itertools.product(orates,repeat=3):
        for r in readies:
            total+=1
            if len(published(A,B,C,oa,ob,oc,r))>1: amb_pub+=1
            if len(flat(A,B,C,oa,ob,oc,r))>1: amb_flat+=1
print(f"{total} input combinations")
print(f"published tree: {amb_pub} ambiguous ({100*amb_pub/total:.1f}%)")
print(f"flat rule:      {amb_flat} ambiguous")
for case in [(100,80,80,.1,.05,.05,10),(100,50,70,.1,.05,.02,10)]:
    print("reviewer case", case[:3], "->", flat(*case))
