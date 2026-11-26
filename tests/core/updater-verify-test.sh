#!/bin/sh
# Update verification tests:
# - checksum verification against SHA256SUMS
# - SLSA provenance subject/digest/signature checks
# - safe archive extraction (absolute paths, traversal, symlinks)
# - release tag sanitisation

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t r10updverify)"
PASS=0
FAIL=0

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

say_pass() {
    echo "[PASS] $1"
    PASS=$((PASS + 1))
}

say_fail() {
    echo "[FAIL] $1"
    FAIL=$((FAIL + 1))
}

assert_ok() {
    msg="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        say_pass "$msg"
    else
        say_fail "$msg"
    fi
}

assert_fail() {
    msg="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        say_fail "$msg"
    else
        say_pass "$msg"
    fi
}

UPDATE_VERIFY_VENDOR_DIR="$PROJECT_ROOT/lib/vendor"
export UPDATE_VERIFY_VENDOR_DIR
# shellcheck source=/dev/null
. "$PROJECT_ROOT/lib/update-verify.sh"

echo "=== Update Verification Test ==="

# --- checksum ---
printf 'release payload\n' > "$TMP_DIR/route10-vpn-client-v9.9.9.tar.gz"
good_digest=$(update_sha256_of "$TMP_DIR/route10-vpn-client-v9.9.9.tar.gz")
printf '%s  route10-vpn-client-v9.9.9.tar.gz\n' "$good_digest" > "$TMP_DIR/SHA256SUMS"

assert_ok "checksum matches SHA256SUMS" \
    update_verify_checksum "$TMP_DIR/route10-vpn-client-v9.9.9.tar.gz" "$TMP_DIR/SHA256SUMS" "route10-vpn-client-v9.9.9.tar.gz"
assert_fail "checksum mismatch is rejected" \
    update_verify_checksum "$TMP_DIR/route10-vpn-client-v9.9.9.tar.gz" "$TMP_DIR/SHA256SUMS" "other.tar.gz"
assert_fail "missing artifact is rejected" \
    update_verify_checksum "$TMP_DIR/absent.tar.gz" "$TMP_DIR/SHA256SUMS" "route10-vpn-client-v9.9.9.tar.gz"

printf '%s  route10-vpn-client-v9.9.9.tar.gz\n' "$(printf 'a%.0s' $(seq 64))" > "$TMP_DIR/SHA256SUMS.bad"
assert_fail "wrong digest in SHA256SUMS is rejected" \
    update_verify_checksum "$TMP_DIR/route10-vpn-client-v9.9.9.tar.gz" "$TMP_DIR/SHA256SUMS.bad" "route10-vpn-client-v9.9.9.tar.gz"

# --- tag sanitisation ---
assert_ok "plain version tag accepted" update_is_safe_tag "v1.2.3"
assert_ok "rc tag accepted" update_is_safe_tag "v1.2.3-rc1"
assert_fail "shell metacharacters in tag rejected" update_is_safe_tag 'v1.2.3; rm -rf /'
assert_fail "path traversal in tag rejected" update_is_safe_tag '../../etc'
assert_fail "empty tag rejected" update_is_safe_tag ""

# --- provenance ---
if command -v jq >/dev/null 2>&1; then
    asset="route10-vpn-client-v9.9.9.tar.gz"

    make_prov() {
        out="$1"
        name="$2"
        digest="$3"
        ptype="$4"
        sigs="$5"
        jq -cn --arg name "$name" --arg digest "$digest" --arg ptype "$ptype" --argjson sigs "$sigs" '
            {
              payloadType: "application/vnd.in-toto+json",
              signatures: (if $sigs > 0 then [{keyid: "test", sig: "test"}] else [] end),
              payload: ({
                  _type: "https://in-toto.io/Statement/v1",
                  subject: [{name: $name, digest: {sha256: $digest}}],
                  predicateType: $ptype,
                  predicate: {buildDefinition: {buildType: "test"}}
              } | tojson | @base64)
            }
        ' > "$out"
    }

    make_prov "$TMP_DIR/ok.intoto.jsonl" "$asset" "$good_digest" "https://slsa.dev/provenance/v1" 1
    assert_ok "valid signed provenance accepted" \
        update_verify_provenance "$TMP_DIR/ok.intoto.jsonl" "$asset" "$good_digest"

    make_prov "$TMP_DIR/wrong.intoto.jsonl" "$asset" "$(printf 'b%.0s' $(seq 64))" "https://slsa.dev/provenance/v1" 1
    assert_fail "provenance digest mismatch rejected" \
        update_verify_provenance "$TMP_DIR/wrong.intoto.jsonl" "$asset" "$good_digest"

    make_prov "$TMP_DIR/unsigned.intoto.jsonl" "$asset" "$good_digest" "https://slsa.dev/provenance/v1" 0
    assert_fail "unsigned provenance rejected" \
        update_verify_provenance "$TMP_DIR/unsigned.intoto.jsonl" "$asset" "$good_digest"

    make_prov "$TMP_DIR/wrongtype.intoto.jsonl" "$asset" "$good_digest" "https://example.com/not-slsa" 1
    assert_fail "non-SLSA predicate rejected" \
        update_verify_provenance "$TMP_DIR/wrongtype.intoto.jsonl" "$asset" "$good_digest"

    make_prov "$TMP_DIR/othername.intoto.jsonl" "someone-else.tar.gz" "$good_digest" "https://slsa.dev/provenance/v1" 1
    assert_fail "provenance for another artifact rejected" \
        update_verify_provenance "$TMP_DIR/othername.intoto.jsonl" "$asset" "$good_digest"

    assert_fail "missing provenance bundle rejected" \
        update_verify_provenance "$TMP_DIR/absent.intoto.jsonl" "$asset" "$good_digest"

    # Sigstore bundle shape, as actually published by the release workflow.
    make_bundle() {
        out="$1"
        name="$2"
        digest="$3"
        source="$4"
        jq -cn --arg name "$name" --arg digest "$digest" --arg source "$source" '
            {
              mediaType: "application/vnd.dev.sigstore.bundle.v0.3+json",
              verificationMaterial: {certificate: {rawBytes: "test"}},
              dsseEnvelope: {
                  payloadType: "application/vnd.in-toto+json",
                  signatures: [{sig: "test"}],
                  payload: ({
                      _type: "https://in-toto.io/Statement/v1",
                      subject: [{name: $name, digest: {sha256: $digest}}],
                      predicateType: "https://slsa.dev/provenance/v0.2",
                      predicate: {
                          buildType: "test",
                          materials: [{uri: ("git+https://github.com/" + $source + "@refs/tags/v9.9.9")}]
                      }
                  } | tojson | @base64)
              }
            }
        ' > "$out"
    }

    make_bundle "$TMP_DIR/bundle.intoto.jsonl" "$asset" "$good_digest" "unflawed-code/route10-vpn-client"
    assert_ok "sigstore bundle with matching source accepted" \
        update_verify_provenance "$TMP_DIR/bundle.intoto.jsonl" "$asset" "$good_digest" "unflawed-code/route10-vpn-client"

    make_bundle "$TMP_DIR/bundle-other.intoto.jsonl" "$asset" "$good_digest" "attacker/route10-vpn-client"
    assert_fail "bundle built from another source repo rejected" \
        update_verify_provenance "$TMP_DIR/bundle-other.intoto.jsonl" "$asset" "$good_digest" "unflawed-code/route10-vpn-client"
else
    echo "[SKIP] jq not available; skipping provenance tests."
fi

# --- release signature ---
# The signature is the only check a compromised repository cannot satisfy, so
# a wrong key, a modified artifact and an absent signature must all fail.
if command -v openssl >/dev/null 2>&1; then
    sig_asset="$TMP_DIR/signed.tar.gz"
    openssl ecparam -name prime256v1 -genkey -noout -out "$TMP_DIR/key.pem" 2>/dev/null
    openssl ec -in "$TMP_DIR/key.pem" -pubout -out "$TMP_DIR/pub.pem" 2>/dev/null
    openssl ecparam -name prime256v1 -genkey -noout -out "$TMP_DIR/other-key.pem" 2>/dev/null
    openssl ec -in "$TMP_DIR/other-key.pem" -pubout -out "$TMP_DIR/other-pub.pem" 2>/dev/null

    printf 'release payload\n' > "$sig_asset"
    openssl dgst -sha256 -sign "$TMP_DIR/key.pem" -out "$sig_asset.sig" "$sig_asset" 2>/dev/null

    assert_ok "valid release signature accepted" \
        update_verify_signature "$sig_asset" "$sig_asset.sig" "$TMP_DIR/pub.pem"

    printf 'tampered\n' >> "$sig_asset"
    assert_fail "signature over a modified artifact rejected" \
        update_verify_signature "$sig_asset" "$sig_asset.sig" "$TMP_DIR/pub.pem"

    printf 'release payload\n' > "$sig_asset"
    assert_fail "signature from a different key rejected" \
        update_verify_signature "$sig_asset" "$sig_asset.sig" "$TMP_DIR/other-pub.pem"
    assert_fail "missing signature rejected" \
        update_verify_signature "$sig_asset" "$TMP_DIR/absent.sig" "$TMP_DIR/pub.pem"
    assert_fail "missing public key rejected" \
        update_verify_signature "$sig_asset" "$sig_asset.sig" "$TMP_DIR/absent.pem"
else
    echo "[SKIP] openssl not available; skipping signature tests."
fi

# --- safe extraction ---
mkdir -p "$TMP_DIR/src/route10-vpn-client-v9.9.9"
echo "setup" > "$TMP_DIR/src/route10-vpn-client-v9.9.9/setup.sh"
( cd "$TMP_DIR/src" && tar -czf "$TMP_DIR/good.tar.gz" . ) >/dev/null 2>&1
assert_ok "clean archive extracts" \
    update_safe_extract "$TMP_DIR/good.tar.gz" "$TMP_DIR/extract-good"
if [ -f "$TMP_DIR/extract-good/route10-vpn-client-v9.9.9/setup.sh" ]; then
    say_pass "extracted tree keeps expected root"
else
    say_fail "extracted tree keeps expected root"
fi

if ln -s /etc/passwd "$TMP_DIR/src/route10-vpn-client-v9.9.9/evil-link" 2>/dev/null; then
    ( cd "$TMP_DIR/src" && tar -czf "$TMP_DIR/symlink.tar.gz" . ) >/dev/null 2>&1
    assert_fail "archive with symlink is refused" \
        update_safe_extract "$TMP_DIR/symlink.tar.gz" "$TMP_DIR/extract-link"
else
    echo "[SKIP] cannot create symlinks here; skipping symlink test."
fi

# Traversal is either refused (tar reports the raw member name) or contained
# (BusyBox tar normalises it in both -t and -x). Either way nothing may land
# outside the staging directory, which is the property that matters.
if command -v python3 >/dev/null 2>&1; then
    python3 - "$TMP_DIR" <<'PY' >/dev/null 2>&1
import io
import os
import sys
import tarfile

root = sys.argv[1]
cases = {
    "traversal.tar.gz": "../escaped.txt",
    "absolute.tar.gz": os.path.join(root, "abs-escape.txt"),
}
for name, member in cases.items():
    with tarfile.open(os.path.join(root, name), "w:gz") as archive:
        info = tarfile.TarInfo(member)
        info.size = 1
        archive.addfile(info, io.BytesIO(b"x"))
PY

    if update_safe_extract "$TMP_DIR/traversal.tar.gz" "$TMP_DIR/extract-evil" >/dev/null 2>&1; then
        say_pass "parent-directory archive accepted but normalised by tar"
    else
        say_pass "parent-directory archive refused"
    fi
    if [ -e "$TMP_DIR/escaped.txt" ]; then
        say_fail "parent-directory archive wrote outside the staging directory"
    else
        say_pass "parent-directory archive wrote nothing outside the staging directory"
    fi

    update_safe_extract "$TMP_DIR/absolute.tar.gz" "$TMP_DIR/extract-abs" >/dev/null 2>&1
    if [ -e "$TMP_DIR/abs-escape.txt" ]; then
        say_fail "absolute-path archive wrote outside the staging directory"
    else
        say_pass "absolute-path archive wrote nothing outside the staging directory"
    fi
else
    echo "[SKIP] python3 not available; skipping traversal test."
fi

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    exit 0
fi
exit 1
