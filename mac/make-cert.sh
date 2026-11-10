#!/bin/zsh
# Run once: a self-signed code-signing certificate, kept in its own small keychain so signing never asks for a
# password. A stable signature lets macOS remember the microphone permission across rebuilds; an ad-hoc one changes
# with every build and macOS would ask again each time.
set -e
cd "${0:A:h}"
KC="$PWD/signing/voxa-signing.keychain-db"
PASS=voxa-local-signing  # guards only this throwaway signing key, nothing else
mkdir -p signing
cat > signing/cert.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Voxa Self-Signed
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config signing/cert.cnf \
  -keyout signing/key.pem -out signing/cert.pem
openssl pkcs12 -export -inkey signing/key.pem -in signing/cert.pem -name "Voxa Self-Signed" \
  -out signing/voxa.p12 -passout "pass:$PASS"
security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"  # no auto-lock
security unlock-keychain -p "$PASS" "$KC"
security import signing/voxa.p12 -k "$KC" -P "$PASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null
rm signing/key.pem signing/voxa.p12  # the key now lives only in the keychain
security find-identity -p codesigning "$KC"
