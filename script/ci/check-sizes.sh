#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${FOUNDRY_OUT:-out}"
forge build >/dev/null 2>&1 || { echo "FAIL: forge build failed"; exit 1; }
OUT="$OUT" python3 - <<'EOF'
import json, os, sys, glob

RUNTIME_LIMIT = 24_576   # EIP-170
INITCODE_LIMIT = 49_152  # EIP-3860
out = os.environ["OUT"]

rows, seen = [], set()
for path in sorted(glob.glob(os.path.join(out, "**", "*.json"), recursive=True)):
    try:
        art = json.load(open(path))
    except (ValueError, OSError):
        continue
    target = (((art.get("metadata") or {}).get("settings") or {}).get("compilationTarget") or {})
    if not target:
        continue
    src, name = next(iter(target.items()))
    if not src.startswith("src/") or not os.path.isfile(src) or os.path.basename(path) != name + ".json":
        continue
    runtime = ((art.get("deployedBytecode") or {}).get("object") or "0x")[2:]
    init = ((art.get("bytecode") or {}).get("object") or "0x")[2:]
    if not init:  # interface or abstract contract: nothing to deploy
        continue
    key = (src, name)
    if key in seen:
        continue
    seen.add(key)
    rows.append((name, src, len(runtime) // 2, len(init) // 2))

if len(rows) < 10:
    print(f"FAIL: found only {len(rows)} src contract artifacts in {out}/ — refusing to pass vacuously")
    sys.exit(1)

bad = [r for r in rows if r[2] > RUNTIME_LIMIT or r[3] > INITCODE_LIMIT]
width = max(len(r[0]) for r in rows)
for name, src, rt, ini in sorted(rows, key=lambda r: -r[2]):
    flag = "OVER" if (rt > RUNTIME_LIMIT or ini > INITCODE_LIMIT) else "ok"
    print(f"  {flag:4}  {name:<{width}}  runtime {rt:>6,} B (margin {RUNTIME_LIMIT - rt:>7,})"
          f"  initcode {ini:>6,} B (margin {INITCODE_LIMIT - ini:>7,})  {src}")
if bad:
    print(f"FAIL: {len(bad)} src contract(s) exceed EIP-170 ({RUNTIME_LIMIT:,} B runtime) "
          f"or EIP-3860 ({INITCODE_LIMIT:,} B initcode): " + ", ".join(r[0] for r in bad))
    sys.exit(1)
print(f"OK: all {len(rows)} deployable src contracts fit EIP-170 / EIP-3860")
EOF
