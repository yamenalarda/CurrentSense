#!/usr/bin/env bash
# Prints the UDID of an available iPhone 15 simulator (falls back to any iPhone).
set -euo pipefail
xcrun simctl list devices available -j | python3 -c '
import json, sys
devs = json.load(sys.stdin)["devices"]
def find(pred):
    best = ""
    for rt, items in devs.items():
        if "iOS" not in rt: continue
        for d in items:
            if d.get("isAvailable", True) and pred(d["name"]): best = d["udid"]
    return best
print(find(lambda n: n == "iPhone 15") or find(lambda n: n.startswith("iPhone")))
'
