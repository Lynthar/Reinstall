#!/bin/bash
# Runs fetch_qcow_hash / verify_qcow from trans.sh against throwaway keys: only a
# checksum file signed by the pinned key may pass, a second key smuggled into the
# .asc must not, and the downloaded image must match the hash. Needs gpg; else SKIP.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
trans=$repo/trans.sh

skip() {
    echo "SKIP check_qcow_verify: $1"
    exit 0
}
for cmd in gpg awk sha256sum sha512sum; do
    command -v "$cmd" >/dev/null || skip "missing $cmd"
done

# Pulls one top-level function out of trans.sh, closing brace included.
extract_fn() {
    awk -v name="$1" '
        index($0, name "() {") == 1 { found = 1 }
        found { print }
        found && $0 == "}" { exit }
    ' "$trans" | grep . || {
        echo "cannot extract $1() from trans.sh" >&2
        exit 1
    }
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Prints the fingerprint of a fresh signing key kept in its own homedir.
gen_key() {
    mkdir -p "$1"
    chmod 700 "$1"
    gpg --homedir "$1" --batch --pinentry-mode loopback --passphrase '' \
        --quick-gen-key "$2" ed25519 sign never >/dev/null 2>&1
    gpg --homedir "$1" --batch --with-colons --fingerprint 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }'
}
real_fpr=$(gen_key "$work/real" "Pinned Signer <pinned@example.invalid>")
gen_key "$work/evil" "Second Signer <second@example.invalid>" >/dev/null
gpg --homedir "$work/real" --batch --armor --export 2>/dev/null >"$work/real.asc"
gpg --homedir "$work/evil" --batch --armor --export 2>/dev/null >"$work/evil.asc"
cat "$work/real.asc" "$work/evil.asc" >"$work/both.asc"

printf 'cloud image bytes' >"$work/ubuntu.img"
printf 'other bytes' >"$work/tampered.img"
printf '%s *ubuntu.img\n' "$(sha256sum "$work/ubuntu.img" | awk '{print $1}')" >"$work/SHA256SUMS.genuine"
printf '%s *ubuntu.img\n' "$(sha256sum "$work/tampered.img" | awk '{print $1}')" >"$work/SHA256SUMS.forged"
for signer in real evil; do
    gpg --homedir "$work/$signer" --batch --detach-sign \
        --output "$work/SHA256SUMS.$signer.gpg" "$work/SHA256SUMS.genuine" 2>/dev/null
done
printf '%s  debian.qcow2\n' "$(sha512sum "$work/ubuntu.img" | awk '{print $1}')" >"$work/SHA512SUMS"

# trans.sh's collaborators, replaced: the mirror is a directory, the key is a file.
cat >"$work/stubs.sh" <<'STUBS'
info() { :; }
apk() { :; }
error_and_exit() {
    echo "error_and_exit: $*" >&2
    exit 1
}
download() {
    case "$1" in
    */keys/ubuntu-cloud.asc) cp "$mirror/key.asc" "$2" ;;
    *) cp "$mirror/$(basename "$1")" "$2" ;;
    esac
}
STUBS
extract_fn fetch_qcow_hash >"$work/fns.sh"
extract_fn verify_qcow >>"$work/fns.sh"

failures=0
fail() {
    echo "    FAIL $1" >&2
    failures=$((failures + 1))
}

# run_case <label> <distro> <key file> <sums> <signer> <image in URL> <bytes on disk> <expect>
# <expect> is "pass" or the start of the error_and_exit reason. Each failing case breaks
# one premise only, so a check that stops rejecting turns its case into a pass.
run_case() {
    local label=$1 distro=$2 key=$3 sums=$4 signer=$5 image=$6 bytes=$7 want=$8 got
    mirror=$work/mirror
    rm -rf "$mirror"
    mkdir -p "$mirror"
    cp "$work/$key" "$mirror/key.asc"
    if [ "$distro" = ubuntu ]; then
        cp "$work/SHA256SUMS.$sums" "$mirror/SHA256SUMS"
        cp "$work/SHA256SUMS.$signer.gpg" "$mirror/SHA256SUMS.gpg"
    else
        cp "$work/SHA512SUMS" "$mirror/SHA512SUMS"
    fi
    if (
        # shellcheck disable=SC1091
        . "$work/stubs.sh"
        # shellcheck disable=SC1091
        . "$work/fns.sh"
        export mirror distro confhome=https://confhome.invalid
        export img="https://mirror.invalid/releases/$image"
        # shellcheck disable=SC2034
        ubuntu_image_key_fpr=$real_fpr
        fetch_qcow_hash
        # shellcheck disable=SC2034
        qcow_file=$work/$bytes
        verify_qcow
    ) >"$work/log" 2>&1; then
        got=pass
    else
        got=$(sed -n 's/^error_and_exit: //p' "$work/log")
    fi
    case "$got" in
    "$want"*) echo "    ok   $label = $want" ;;
    *) fail "$label: expected '$want', got '${got:-no error_and_exit}'" ;;
    esac
}

unsigned="SHA256SUMS is not signed by the Ubuntu cloud image key"
mismatch="Image hash mismatch"

echo "== signature must come from the pinned key =="
run_case "pinned key, genuine sums" ubuntu real.asc genuine real ubuntu.img ubuntu.img pass
run_case "pinned key first, second key signs" ubuntu both.asc genuine evil ubuntu.img ubuntu.img "$unsigned"
run_case "second key alone" ubuntu evil.asc genuine evil ubuntu.img ubuntu.img "$unsigned"
run_case "signer missing from the .asc" ubuntu real.asc genuine evil ubuntu.img ubuntu.img "$unsigned"
run_case "sums altered after signing" ubuntu real.asc forged real ubuntu.img tampered.img "$unsigned"

echo "== downloaded image must match the signed hash =="
run_case "ubuntu image tampered after download" ubuntu real.asc genuine real ubuntu.img tampered.img "$mismatch"
run_case "debian genuine" debian real.asc - - debian.qcow2 ubuntu.img pass
run_case "debian image tampered after download" debian real.asc - - debian.qcow2 tampered.img "$mismatch"
run_case "debian image not listed" debian real.asc - - other.qcow2 ubuntu.img "other.qcow2 not listed"

echo "== checksums are verified before the disk is touched =="
for arm in debian ubuntu; do
    if extract_fn trans | awk -v arm="$arm)" '
        $1 == arm { in_arm = 1; next }
        in_arm && $1 == "fetch_qcow_hash" { fetch = NR }
        in_arm && $1 == "create_part" { part = NR }
        in_arm && $1 == ";;" { done = 1; exit !(fetch && part && fetch < part) }
        END { if (!done) exit 1 }'; then
        echo "    ok   $arm: fetch_qcow_hash precedes create_part"
    else
        echo "    FAIL $arm: fetch_qcow_hash must run before create_part" >&2
        failures=$((failures + 1))
    fi
done

if [ "$failures" != 0 ]; then
    echo "check_qcow_verify: $failures assertion(s) failed" >&2
    exit 1
fi
echo "check_qcow_verify: ok"
exit 0
