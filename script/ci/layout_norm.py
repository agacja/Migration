import json, sys
d = json.load(sys.stdin)
def strip(t):
    import re
    return re.sub(r"\)(\d+)", ")", t)
for s in d["storage"]:
    print("slot", s["slot"], s["offset"], s["label"], strip(s["type"]), sep=":")
for tname, t in sorted(d.get("types", {}).items()):
    if "members" not in t:
        continue
    for m in t["members"]:
        print("member", strip(tname), m["slot"], m["offset"], m["label"], strip(m["type"]), t.get("numberOfBytes"), sep=":")
