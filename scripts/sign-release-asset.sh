#!/bin/sh
# Sign a published release asset and attach the signature.
#
#   ./scripts/sign-release-asset.sh v1.2.0
#   ./scripts/sign-release-asset.sh --dry-run v1.2.0
#
# Downloads the archive the release workflow published -- never a local rebuild,
# whose bytes can differ -- checks it against the published SHA256SUMS, signs it
# with the offline key, uploads <asset>.sig with --clobber, then re-downloads the
# signature and verifies it with the same vendored check the routers run.
#
# Re-running is the recovery path after the release workflow re-uploads the
# archive: the previous signature no longer matches and must be replaced.

set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GITHUB_REPO="${GITHUB_REPO:-unflawed-code/route10-vpn-client}"

usage() {
    echo "Usage: $0 [--dry-run] <tag>" >&2
    echo "  e.g. $0 v1.2.0" >&2
    echo "  --dry-run downloads, checks and signs but does not upload." >&2
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

dry_run=0
tag=""
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) dry_run=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $arg" ;;
        *)
            [ -z "$tag" ] || die "only one tag may be given"
            tag="$arg"
            ;;
    esac
done

[ -n "$tag" ] || { usage; exit 1; }

# The tag is interpolated into API paths and file names; validate it as the
# updater does rather than trusting the command line.
printf '%s' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$' \
    || die "refusing unsafe tag: $tag"

command -v gh >/dev/null 2>&1 || die "gh is required"
command -v openssl >/dev/null 2>&1 || die "openssl is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"

asset="route10-vpn-client-${tag}.tar.gz"
key="${RELEASE_SIGNING_KEY:-${REPO_DIR}/.release-keys/release-signing-key.pem}"

[ -f "$key" ] || die "signing key not found: $key"
[ -f "${REPO_DIR}/lib/vendor/route10-signature.sh" ] \
    || die "vendored verifier missing: ${REPO_DIR}/lib/vendor/route10-signature.sh"

work=$(mktemp -d 2>/dev/null || echo "/tmp/route10-sign-release.$$")
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT INT TERM

echo "Fetching published assets for ${tag} from ${GITHUB_REPO}"
gh release download "$tag" --repo "$GITHUB_REPO" --pattern "$asset" --dir "$work" >/dev/null 2>&1 || {
    die "${asset} is not published on ${tag} (has the release workflow finished?)"
}
gh release download "$tag" --repo "$GITHUB_REPO" --pattern 'SHA256SUMS' --dir "$work" >/dev/null 2>&1 || {
    die "SHA256SUMS is not published on ${tag}"
}

echo "Checking the downloaded archive against SHA256SUMS"
( cd "$work" && sha256sum -c SHA256SUMS >/dev/null ) || die "checksum mismatch for ${asset}"

echo "Signing ${asset} with ${key}"
( cd "$REPO_DIR" && ./scripts/sign-release.sh "${work}/${asset}" "$key" ) || die "signing failed"

# The public key has to come from project.conf, because that is where the routers
# read it from; a signature validated against any other key proves nothing.
( cd "$REPO_DIR" && sh -c '. ./project.conf; printf "%s\n" "${VPN_UPDATE_PUBKEY:-}"' ) \
    | tr -d '\r' > "$work/release-pub.pem"
[ -s "$work/release-pub.pem" ] || die "VPN_UPDATE_PUBKEY is empty in project.conf"

if ! gh release view "$tag" --repo "$GITHUB_REPO" --json assets --jq '.assets[].name' 2>/dev/null \
    | grep -qxF "${asset}.intoto.jsonl"; then
    echo "WARNING: ${asset}.intoto.jsonl is not on the release; provenance checks will fail on devices" >&2
fi

if [ "$dry_run" = "1" ]; then
    echo "Dry run: not uploading. Signature written to ${work}/${asset}.sig"
    verify_target="${work}/${asset}.sig"
else
    echo "Uploading ${asset}.sig to ${tag}"
    gh release upload "$tag" --repo "$GITHUB_REPO" "${work}/${asset}.sig" --clobber >/dev/null \
        || die "upload failed"

    # Verify the copy that is actually on the release, not the local one.
    mkdir -p "$work/check"
    gh release download "$tag" --repo "$GITHUB_REPO" --pattern "${asset}.sig" --dir "$work/check" >/dev/null 2>&1 \
        || die "uploaded signature could not be downloaded again"
    verify_target="${work}/check/${asset}.sig"
fi

echo "Verifying with the same check the routers run"
sh -c ". '${REPO_DIR}/lib/vendor/route10-signature.sh'; update_verify_signature '${work}/${asset}' '${verify_target}' '${work}/release-pub.pem'" \
    || die "device-side verification failed"

echo
echo "Signed ${asset}"
echo "  sha256 $(sha256sum "${work}/${asset}" | awk '{print $1}')"
if [ "$dry_run" = "1" ]; then
    echo "  upload with: gh release upload ${tag} ${work}/${asset}.sig --clobber"
    echo "  (signature kept at ${work}/${asset}.sig; rerun without --dry-run to upload)"
    trap - EXIT INT TERM
fi
