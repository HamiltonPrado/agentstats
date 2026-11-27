#!/bin/zsh
# Lista as frases do código (as que o compilador extrai: Text("…"), String(localized: …), etc.)
# que ainda não têm tradução em Resources/en.lproj/Localizable.strings, e as traduções que já não têm uso.
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
# As frases passadas a L("…") e às funções abaixo não são extraídas pelo compilador: procuram-se no código.
source = "".join(open(f, encoding="utf-8").read() for f in glob.glob("Sources/**/*.swift", recursive=True))
# Também as funções da app que traduzem o texto que recebem (note, textLink, os argumentos `more:`).
for lit in re.findall(r'(?:\b(?:L|note|textLink)\(|more: )"((?:[^"\\]|\\.)*)"', source):
    if "\\(" in lit:   # interpolação: não é uma chave fixa
        continue
    try:
        k = json.loads('"' + lit + '"')
    except ValueError:
        continue
    if k not in have and re.search(r"[À-ú]|\b(de|em|para|não|os|as|um|uma|que|com|sem)\b", k):
        missing.add(k)
for k in sorted(missing): print(k)
print(f"{len(missing)} sem tradução", file=sys.stderr)

# O inverso: traduções de frases que já não existem. As do L("…") não são extraídas pelo compilador,
# por isso conta também o texto entre aspas no código.
extracted = {e["key"] for f in glob.glob(sys.argv[1] + "/*.stringsdata") for t in json.load(open(f))["tables"].values() for e in t}
unused = [k for k in have if k not in extracted and json.dumps(k, ensure_ascii=False) not in source]
for k in sorted(unused): print("sem uso:", k)
print(f"{len(unused)} sem uso", file=sys.stderr)
PY
