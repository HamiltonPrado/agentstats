#!/bin/zsh
# Assina a app com a identidade fixa do AgentStats.
#
# O macOS prende as permissões (Acessibilidade, gravação de ecrã, áudio, pastas) ao "designated requirement".
# Com assinatura ad-hoc isso é o hash do binário, que muda em cada build. Com o certificado fixo é
# identificador + certificado, igual em todas as versões. Só o identificador não chegava: qualquer binário
# que o usasse herdava as permissões.
#
# uso: Scripts/sign.sh <app>
#   SIGNING_REQUIRED=1        falha em vez de assinar ad-hoc (releases)
#   SIGNING_KEYCHAIN=<path>   porta-chaves onde está a chave (CI)
#   SIGNING_CERT_FILE=<path>  outra impressão digital (testes)
set -euo pipefail

APP="${1:?falta o caminho da app}"
CERT_FILE="${SIGNING_CERT_FILE:-${0:A:h}/signing-cert.sha1}"
REQUIRED="${SIGNING_REQUIRED:-0}"
KEYCHAIN="${SIGNING_KEYCHAIN:-}"
IDENTIFIER="local.agentstats"

adhoc() {
    if [[ "$REQUIRED" == "1" ]]; then
        echo "erro: $1. Uma release nunca sai com assinatura ad-hoc." >&2
        exit 1
    fi
    codesign --force --sign - "$APP"
    echo "⚠️  Assinatura ad-hoc ($1): instalada, esta build perde as permissões do macOS."
    exit 0
}

[[ -f "$CERT_FILE" ]] || adhoc "sem Scripts/signing-cert.sha1"
sha="$(tr -d '[:space:]' < "$CERT_FILE")"
if [[ ${#sha} -ne 40 || "$sha" == *[^0-9A-Fa-f]* ]]; then
    echo "erro: impressão digital inválida em $CERT_FILE" >&2
    exit 1
fi

where=()
[[ -n "$KEYCHAIN" ]] && where=("$KEYCHAIN")
identities="$(security find-identity -p codesigning "${where[@]}")"
[[ "${identities:u}" == *"${sha:u}"* ]] || adhoc "a chave de assinatura não está neste Mac"

requirement="identifier \"$IDENTIFIER\" and certificate leaf = H\"${sha:l}\""
sign_args=(--force --timestamp=none --identifier "$IDENTIFIER" --sign "${sha:u}" --requirements "=designated => $requirement")
[[ -n "$KEYCHAIN" ]] && sign_args+=(--keychain "$KEYCHAIN")

# Se isto falhar (pedido do porta-chaves recusado, por exemplo), não cai para ad-hoc: falha.
codesign "${sign_args[@]}" "$APP"
codesign --verify --strict --test-requirement="=$requirement" "$APP"
echo "🔏 Assinada com a identidade fixa do AgentStats."
