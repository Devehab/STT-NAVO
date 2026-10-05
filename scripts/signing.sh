#!/bin/bash
# Picks a stable code-signing identity for Navo so macOS keeps the Accessibility and
# Microphone permissions across rebuilds (they are tied to the app's signature).
#   1. NAVO_SIGN_IDENTITY if set
#   2. an "Apple Development" or "Developer ID Application" certificate
#   3. a self-signed "Navo Local Signing" certificate, created once in the login keychain
#   4. ad-hoc ("-"), which changes on every build
# Prints the identity name on stdout. Sourced by build-app.sh.

NAVO_LOCAL_CERT="Navo Local Signing"

navo_create_local_identity() {
  local tmp keychain
  tmp="$(mktemp -d)"
  keychain="$HOME/Library/Keychains/login.keychain-db"
  cat > "$tmp/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAVO_LOCAL_CERT
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  # /usr/bin/openssl is LibreSSL, whose PKCS#12 output the macOS keychain can import.
  if /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/openssl.cnf" \
       -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1 \
     && /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
       -name "$NAVO_LOCAL_CERT" -out "$tmp/identity.p12" -passout pass:navo >/dev/null 2>&1 \
     && security import "$tmp/identity.p12" -k "$keychain" -P navo -T /usr/bin/codesign >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"
  return 1
}

navo_signing_identity() {
  if [ -n "${NAVO_SIGN_IDENTITY:-}" ]; then
    echo "$NAVO_SIGN_IDENTITY"
    return
  fi
  local apple
  apple="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')"
  if [ -n "$apple" ]; then
    echo "$apple"
    return
  fi
  if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAVO_LOCAL_CERT\""; then
    echo "==> Creating a local signing certificate \"$NAVO_LOCAL_CERT\" (one time)" >&2
    navo_create_local_identity || echo "    Could not create it, falling back to ad-hoc signing." >&2
  fi
  if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAVO_LOCAL_CERT\""; then
    echo "$NAVO_LOCAL_CERT"
    return
  fi
  echo "-"
}
