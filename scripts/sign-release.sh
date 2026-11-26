#!/bin/sh
# Sign a release archive with the offline release signing key.
#
#   ./scripts/sign-release.sh dist/route10-vpn-client-v1.2.0.tar.gz
#
# Produces <archive>.sig, which is published next to the archive as a release
# asset and verified by scripts/updater.sh on the router.
#
# The private key is read from $RELEASE_SIGNING_KEY (default:
# .release-keys/release-signing-key.pem). It must never be committed, copied to
# the router, or stored in CI: keeping it off GitHub is the entire point.

set -eu

if [ $# -lt 1 ]; then
    echo "Usage: $0 <archive> [key-file]" >&2
    exit 1
fi

archive="$1"
[ -f "$archive" ] || { echo "ERROR: no such file: $archive" >&2; exit 1; }

key="${2:-${RELEASE_SIGNING_KEY:-.release-keys/release-signing-key.pem}}"
[ -f "$key" ] || { echo "ERROR: signing key not found: $key" >&2; exit 1; }

command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl is required" >&2; exit 1; }

openssl dgst -sha256 -sign "$key" -out "${archive}.sig" "$archive" || {
    echo "ERROR: signing failed" >&2
    exit 1
}

# Self-check against the key the routers will actually trust: the PEM block in
# project.conf. This catches a wrong signing key here rather than on every
# router refusing the update.
pubkey="${RELEASE_PUBLIC_KEY:-}"
temp_pubkey=""
if [ -z "$pubkey" ] && [ -f project.conf ]; then
    temp_pubkey="/tmp/release-pub.$$"
    if command -v mktemp >/dev/null 2>&1; then
        temp_pubkey="$(mktemp)" || temp_pubkey="/tmp/release-pub.$$"
    fi
    # The block is a shell assignment, so trim the "NAME='" prefix and the
    # closing quote to leave a bare PEM for openssl.
    sed -n '/-----BEGIN PUBLIC KEY-----/,/-----END PUBLIC KEY-----/p' project.conf \
        | sed 's/^.*-----BEGIN PUBLIC KEY-----/-----BEGIN PUBLIC KEY-----/; s/-----END PUBLIC KEY-----.*$/-----END PUBLIC KEY-----/' \
        > "$temp_pubkey"
    [ -s "$temp_pubkey" ] && pubkey="$temp_pubkey"
fi

if [ -n "$pubkey" ] && [ -f "$pubkey" ]; then
    if ! openssl dgst -sha256 -verify "$pubkey" -signature "${archive}.sig" "$archive" >/dev/null 2>&1; then
        [ -n "$temp_pubkey" ] && rm -f "$temp_pubkey"
        echo "ERROR: signature does not verify against the project.conf public key; wrong signing key?" >&2
        exit 1
    fi
    [ -n "$temp_pubkey" ] && rm -f "$temp_pubkey"
    echo "Signed and verified: ${archive}.sig"
else
    echo "Signed: ${archive}.sig (no public key in project.conf to self-verify against)"
fi
