#!/bin/bash
# Prints the path of a private keychain holding the stable "Spare Local Signing" identity, creating it once.
# Ad-hoc signatures change with every build, so macOS would forget Full Disk Access after each update. A fixed
# self-signed identity keeps the designated requirement, and the permission, stable.
# Keep ~/Library/Keychains/spare-signing.keychain-db and ~/.config/spare/signing-password: losing them means
# granting Full Disk Access once more after the next update.
set -euo pipefail
NAME="Spare Local Signing"
KEYCHAIN="$HOME/Library/Keychains/spare-signing.keychain-db"
SECRET_DIR="$HOME/.config/spare"
PASSWORD_FILE="$SECRET_DIR/signing-password"

if [ ! -f "$KEYCHAIN" ]; then
    if [ -f "$(dirname "$0")/../updates/signing-certificate.txt" ] && [ "${SPARE_NEW_SIGNING_IDENTITY:-0}" != "1" ]; then
        echo "The signing keychain is missing, but releases are pinned to an existing certificate." >&2
        echo "Restore $KEYCHAIN, or set SPARE_NEW_SIGNING_IDENTITY=1 to start over (people then grant Full Disk Access again)." >&2
        exit 1
    fi
    mkdir -p "$SECRET_DIR"
    chmod 700 "$SECRET_DIR"
    if [ ! -f "$PASSWORD_FILE" ]; then
        (umask 077; openssl rand -hex 24 > "$PASSWORD_FILE")
    fi
    PASSWORD="$(cat "$PASSWORD_FILE")"
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
    openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -config "$WORK/cert.cnf" \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
    openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
        -passout "pass:$PASSWORD" -out "$WORK/identity.p12"
    security create-keychain -p "$PASSWORD" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"
    security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
fi

security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN"
echo "$KEYCHAIN"
