#!/bin/zsh
# Lista as frases do código (as que o compilador extrai: Text("…"), String(localized: …), etc.)
# que ainda não têm tradução em Resources/en.lproj/Localizable.strings.
# uso: Scripts/check-translations.sh
set -euo pipefail
cd "${0:A:h}/.."
out="$(mktemp -d "${TMPDIR:-/tmp}/agentstats-strings.XXXXXX")"
plugins="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins"
xcrun swiftc -parse-as-library -c $(find Sources/AgentStats -name '*.swift') -module-name AgentStats \
    -swift-version 6 -target arm64-apple-macos14.0 -plugin-path "$plugins" -plugin-path "$plugins/testing" \
    -emit-localized-strings -emit-localized-strings-path "$out" -o /dev/null -wmo >/dev/null 2>&1 || true
/usr/bin/python3 -I - "$out" Resources/en.lproj/Localizable.strings <<'PY'
import glob, json, re, sys
import subprocess
have = set(json.loads(subprocess.run(["/usr/bin/plutil", "-convert", "json", "-o", "-", sys.argv[2]],
                                     capture_output=True, check=True).stdout).keys())
missing = set()
for f in glob.glob(sys.argv[1] + "/*.stringsdata"):
    for table in json.load(open(f))["tables"].values():
        for e in table:
            k = e["key"]
            if k.startswith("do shell script"):   # AppleScript, não é interface
                continue
            if k not in have and re.search(r"[A-Za-zÀ-ú]{3}", k) and re.search(r"[À-ú]|\b(de|em|para|não|os|as|um|uma|que|com|sem)\b", k):
                missing.add(k)
for k in sorted(missing): print(k)
print(f"{len(missing)} sem tradução", file=sys.stderr)
PY
