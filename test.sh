#!/bin/zsh
# Corre os testes (Swift Testing). Com só as Command Line Tools, o plugin de macros do
# Swift Testing está numa subpasta que o compilador não procura sozinho.
set -euo pipefail
cd "$(dirname "$0")"
PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
if [ -d "$PLUGINS" ]; then
    swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
    swift test "$@"   # com o Xcode instalado o plugin já é encontrado
fi
