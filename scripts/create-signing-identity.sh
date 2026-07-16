#!/bin/sh
set -eu

identity_name="simulator-mcp-local"
keychain="$HOME/Library/Keychains/login.keychain-db"

if ! valid_identities="$(security find-identity -v -p codesigning "$keychain" 2>&1)"; then
    echo "Could not inspect code-signing identities in $keychain: $valid_identities" >&2
    exit 1
fi
case "$valid_identities" in
*\"$identity_name\"*)
    echo "A usable code-signing identity and private key named $identity_name already exist; no keychain changes were made."
    printf '%s\n' "$valid_identities"
    exit 0
    ;;
esac

certificate_status=0
security find-certificate -c "$identity_name" "$keychain" >/dev/null 2>&1 \
    || certificate_status=$?
case "$certificate_status" in
0)
    echo "A certificate named $identity_name exists without a usable code-signing identity and private key. Remove or repair that certificate, then rerun this script." >&2
    exit 1
    ;;
44) ;;
*)
    echo "Could not inspect certificates in $keychain (security exit $certificate_status); no keychain changes were made." >&2
    exit 1
    ;;
esac

workdir="$(mktemp -d "${TMPDIR:-/tmp}/simulator-mcp-signing.XXXXXX")"
chmod 700 "$workdir"
trap 'rm -rf "$workdir"' EXIT HUP INT TERM

cat > "$workdir/openssl.cnf" <<EOF
[req]
distinguished_name = subject
x509_extensions = code_signing
prompt = no

[subject]
CN = $identity_name

[code_signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = 1.3.6.1.5.5.7.3.3
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF

openssl req -new -newkey rsa:2048 -nodes -x509 -sha256 -days 3650 \
    -config "$workdir/openssl.cnf" \
    -keyout "$workdir/private-key.pem" \
    -out "$workdir/certificate.pem"

archive_password="$(uuidgen)"
openssl pkcs12 -export -legacy \
    -inkey "$workdir/private-key.pem" \
    -in "$workdir/certificate.pem" \
    -name "$identity_name" \
    -passout "pass:$archive_password" \
    -out "$workdir/identity.p12"

security import "$workdir/identity.p12" \
    -k "$keychain" \
    -P "$archive_password" \
    -T /usr/bin/codesign \
    -T /usr/bin/security
security add-trusted-cert -r trustRoot -p codeSign \
    -k "$keychain" "$workdir/certificate.pem"

valid_identities="$(security find-identity -v -p codesigning "$keychain")"
printf '%s\n' "$valid_identities"
case "$valid_identities" in
*\"$identity_name\"*) ;;
*)
    echo "The imported certificate did not become a usable code-signing identity and private key." >&2
    exit 1
    ;;
esac
