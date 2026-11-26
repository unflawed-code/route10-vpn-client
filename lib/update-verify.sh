#!/bin/sh
# Route10 Update Verification Library
# Network-free helpers used by scripts/updater.sh to validate a release
# artifact before it is extracted or applied.
#
# Each helper prints a short human-readable reason on stdout and returns
# non-zero on failure, so the caller can log it verbatim.

# sha256 digest of a file (empty when unavailable).
update_sha256_of() {
    [ -f "$1" ] || return 1
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

# Release tags are interpolated into URLs and filesystem paths, so only accept
# plain version tags.
update_is_safe_tag() {
    [ -n "${1:-}" ] || return 1
    printf '%s' "$1" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$'
}

# Verify the digest of file $1 against the entry for $3 inside the SHA256SUMS
# file $2. Prints the verified digest on success.
update_verify_checksum() {
    local file="$1"
    local sums="$2"
    local asset="$3"
    local expected
    local actual

    [ -s "$file" ] || { echo "artifact is missing or empty"; return 1; }
    [ -s "$sums" ] || { echo "SHA256SUMS is missing or empty"; return 1; }

    expected=$(awk -v n="$asset" '{ f = $2; sub(/^\*/, "", f); if (f == n) { print $1; exit } }' "$sums")
    [ -n "$expected" ] || { echo "$asset is not listed in SHA256SUMS"; return 1; }

    actual=$(update_sha256_of "$file") || { echo "unable to hash $asset"; return 1; }
    if [ "$expected" != "$actual" ]; then
        echo "checksum mismatch for $asset (expected $expected, got $actual)"
        return 1
    fi

    echo "$actual"
}

# Verify that the SLSA provenance bundle $1 carries a signed statement whose
# subject is $2 with digest $3. Prints the attested digest on success.
#
# This proves the artifact is the one the release workflow attested, but it
# checks no signature: it cannot tell a genuine attestation from a forged one.
# update_verify_signature below is the authoritative check, because it needs a
# secret the repository does not hold.
update_verify_provenance() {
    local prov="$1"
    local asset="$2"
    local digest="$3"
    local expected_source="${4:-}"
    local covered

    [ -s "$prov" ] || { echo "provenance bundle is missing or empty"; return 1; }
    command -v jq >/dev/null 2>&1 || { echo "jq is required to verify provenance"; return 1; }

    # Provenance is published either as a bare DSSE envelope or wrapped in a
    # Sigstore bundle (mediaType application/vnd.dev.sigstore.bundle...); accept
    # both shapes. When $4 is given, the statement must also name that source
    # repository, so an attestation for some other project cannot be replayed.
    covered=$(jq -r --arg name "$asset" --arg expected "$expected_source" '
        (.dsseEnvelope // .) as $env
        | select($env.payloadType == "application/vnd.in-toto+json")
        | select(($env.signatures | type) == "array" and ($env.signatures | length) > 0)
        | ($env.payload | @base64d | fromjson) as $stmt
        | select(($stmt.predicateType | type) == "string")
        | select($stmt.predicateType | startswith("https://slsa.dev/provenance/"))
        | ([ ( ($stmt.predicate.materials // [])[]? | .uri // empty ),
             ( ($stmt.predicate.buildDefinition.resolvedDependencies // [])[]? | .uri // empty ),
             ( $stmt.predicate.invocation.configSource.uri // empty ),
             ( $stmt.predicate.buildDefinition.externalParameters.source.uri // empty )
           ] | map(select(. != "")) | join(" ")) as $sources
        | select($expected == "" or ($sources | contains($expected)))
        | $stmt.subject[]?
        | select(.name == $name)
        | .digest.sha256 // empty
    ' "$prov" 2>/dev/null) || true

    if [ -z "$covered" ]; then
        echo "no signed SLSA statement covers $asset${expected_source:+ built from $expected_source}"
        return 1
    fi
    printf '%s\n' "$covered" | grep -Fxq "$digest" || {
        echo "attested digest does not match the downloaded artifact"
        return 1
    }

    echo "$digest"
}

# Detached-signature verification is vendored from the route10-update-verifier
# repo so the check has a single upstream source. Do not edit lib/vendor/ by
# hand: refresh it with that repo's scripts/sync-verifier.sh and let CI verify
# the digest.
UPDATE_VERIFY_VENDOR_DIR="${UPDATE_VERIFY_VENDOR_DIR:-${REMOTE_DIR:+${REMOTE_DIR}/lib/vendor}}"
if [ ! -f "${UPDATE_VERIFY_VENDOR_DIR}/route10-signature.sh" ]; then
    echo "vendored signature verifier not found (set UPDATE_VERIFY_VENDOR_DIR)" >&2
    return 1
fi
# shellcheck source=/dev/null
. "${UPDATE_VERIFY_VENDOR_DIR}/route10-signature.sh"

# Extract archive $1 into $2, refusing absolute paths, parent-directory escapes
# and symlinks so a tampered archive cannot write outside the staging directory.
#
# The name check is defence in depth: BusyBox tar already rewrites "../x",
# "a/../../x" and "/abs/x" to plain relative names in both -t and -x, so such
# an archive is silently contained rather than refused there. The check still
# fires on tar builds that report the raw member names.
update_safe_extract() {
    local archive="$1"
    local dest="$2"
    local listing="${dest}.entries"
    local entry

    [ -s "$archive" ] || { echo "archive is missing or empty"; return 1; }
    mkdir -p "$dest" || { echo "cannot create staging directory"; return 1; }

    if ! tar -tzf "$archive" > "$listing" 2>/dev/null; then
        echo "archive is not a readable tar.gz"
        return 1
    fi

    while IFS= read -r entry; do
        case "$entry" in
            /*)
                echo "refusing absolute path in archive: $entry"
                rm -f "$listing"
                return 1
                ;;
            ..|../*|*/../*|*/..)
                echo "refusing parent-directory path in archive: $entry"
                rm -f "$listing"
                return 1
                ;;
        esac
    done < "$listing"
    rm -f "$listing"

    tar -xzf "$archive" -C "$dest" || { echo "extraction failed"; return 1; }

    if [ -n "$(find "$dest" -type l 2>/dev/null | head -n 1)" ]; then
        echo "archive contains symlinks; refusing to apply"
        return 1
    fi

    return 0
}
