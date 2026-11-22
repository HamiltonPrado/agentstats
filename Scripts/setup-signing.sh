#!/bin/zsh
# Corre-se UMA vez, pelo dono do repositório, no Terminal: cria a chave de assinatura do AgentStats.
# - a chave fica no porta-chaves de login deste Mac e nos segredos do GitHub; nunca no git nem no ecrã
# - no repositório fica só Scripts/signing-cert.sha1, a impressão digital, que é pública
# Uma chave nova muda a identidade da app e todos os utilizadores perdem as permissões: por isso recusa repetir.
set -euo pipefail

HERE="${0:A:h}"
CERT_FILE="$HERE/signing-cert.sha1"
REPO="HamiltonPrado/agentstats"
NAME="AgentStats Signing"
OPENSSL=/usr/bin/openssl   # o LibreSSL do macOS: o porta-chaves não importa os p12 do OpenSSL 3+

fail() {
    echo "erro: $1" >&2
    exit 1
}

[[ -e "$CERT_FILE" ]] && fail "já existe uma identidade ($CERT_FILE). Não criei outra."
command -v gh >/dev/null || fail "falta o GitHub CLI (gh)."
gh auth status >/dev/null 2>&1 || fail "o gh não tem sessão iniciada (gh auth login)."
secrets="$(gh secret list --repo "$REPO")" || fail "não consegui ler os segredos de $REPO."
[[ "$secrets" == *SIGNING_P12* ]] && fail "o GitHub já tem uma chave de assinatura. Não a substituí."

cat <<TEXT
Vou criar a chave de assinatura do AgentStats (20 anos) e guardá-la em dois sítios:
  • o porta-chaves de login deste Mac, como "$NAME"
  • os segredos do GitHub de $REPO

Quem tiver esta chave consegue fazer uma app passar pelo AgentStats e herdar as permissões dele.

O macOS vai perguntar se o codesign pode usar a chave e pede a password do Mac (só ao macOS, não a este script):
  • "Permitir sempre": as builds locais assinam sem perguntar, mas qualquer programa teu também o conseguiria
  • "Permitir": pergunta em cada build, é mais seguro

TEXT
printf 'Enter para continuar, Ctrl+C para desistir: '
read -r

umask 077
work="$(mktemp -d "${TMPDIR:-/tmp}/agentstats-setup.XXXXXX")"
login="$(security login-keychain | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')"
sha=""
imported=0
finished=0

cleanup() {
    for file in key.pem cert.pem cert.cnf signing.p12 probe; do
        [[ -f "$work/$file" ]] && rm -f "$work/$file"
    done
    rmdir "$work" 2>/dev/null || true
    if (( imported && ! finished )); then
        # Só a identidade que este script acabou de criar, pela impressão digital.
        security delete-identity -Z "$sha" "$login" >/dev/null 2>&1 || true
        echo "Não terminou: tirei do porta-chaves a chave que tinha criado. Podes correr outra vez." >&2
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

cat > "$work/cert.cnf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

"$OPENSSL" req -new -newkey rsa:3072 -nodes -x509 -days 7300 -config "$work/cert.cnf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
P12_PASSWORD="$("$OPENSSL" rand -hex 24)"
export P12_PASSWORD
"$OPENSSL" pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$NAME" \
    -out "$work/signing.p12" -passout env:P12_PASSWORD
sha="$("$OPENSSL" x509 -in "$work/cert.pem" -outform DER | shasum -a 1 | cut -d' ' -f1 | tr 'a-f' 'A-F')"

security import "$work/signing.p12" -k "$login" -P "$P12_PASSWORD" >/dev/null
imported=1

echo "A testar a assinatura. Responde ao pedido do macOS…"
cp /usr/bin/true "$work/probe"
codesign --force --timestamp=none --identifier local.agentstats.probe --keychain "$login" --sign "$sha" "$work/probe" \
    || fail "o macOS não deixou usar a chave."

# Pelo stdin, para os valores não aparecerem no ecrã, no histórico nem na lista de processos.
/usr/bin/base64 -i "$work/signing.p12" | gh secret set SIGNING_P12_BASE64 --repo "$REPO"
if ! printf '%s' "$P12_PASSWORD" | gh secret set SIGNING_P12_PASSWORD --repo "$REPO"; then
    gh secret delete SIGNING_P12_BASE64 --repo "$REPO" >/dev/null 2>&1 || true
    fail "não consegui guardar a password da chave no GitHub."
fi
unset P12_PASSWORD

printf '%s\n' "$sha" > "$CERT_FILE"
chmod 644 "$CERT_FILE"
finished=1

cat <<TEXT

✅ Pronto.
  • chave no porta-chaves de login e nos segredos do GitHub
  • impressão digital em Scripts/signing-cert.sha1 (vai no commit)
  • cópia de segurança, se quiseres: Acesso a Porta-chaves → "$NAME" → Exportar
TEXT
