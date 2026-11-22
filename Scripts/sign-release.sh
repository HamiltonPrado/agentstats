#!/bin/zsh
# CI: assina a release. Corre depois dos testes e da compilação, para nenhum código compilado ou testado
# ter a chave ao alcance, e apaga o porta-chaves temporário ao sair, corra bem ou mal.
#
# uso: SIGNING_P12_BASE64=… SIGNING_P12_PASSWORD=… Scripts/sign-release.sh <app>
set -euo pipefail

APP="${1:?falta o caminho da app}"
HERE="${0:A:h}"
: "${SIGNING_P12_BASE64:?falta o segredo SIGNING_P12_BASE64. Corre Scripts/setup-signing.sh uma vez}"
: "${SIGNING_P12_PASSWORD:?falta o segredo SIGNING_P12_PASSWORD}"
p12_base64="$SIGNING_P12_BASE64"
p12_password="$SIGNING_P12_PASSWORD"
# Os comandos seguintes não os recebem no ambiente.
unset SIGNING_P12_BASE64 SIGNING_P12_PASSWORD

umask 077
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/agentstats-signing.XXXXXX")"
keychain="$work/signing.keychain-db"
p12="$work/signing.p12"

cleanup() {
    security delete-keychain "$keychain" >/dev/null 2>&1 || true
    [[ -f "$p12" ]] && rm -f "$p12"
    rmdir "$work" 2>/dev/null || true
}
trap cleanup EXIT

printf '%s' "$p12_base64" | /usr/bin/base64 -D > "$p12"
keychain_password="$(/usr/bin/openssl rand -hex 24)"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$p12" -k "$keychain" -P "$p12_password" -T /usr/bin/codesign >/dev/null
rm -f "$p12"
security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null 2>&1

SIGNING_REQUIRED=1 SIGNING_KEYCHAIN="$keychain" "$HERE/sign.sh" "$APP"
