#!/bin/bash
# Runs prepare_debian_sources from trans.sh with the mirrors stubbed: every suite apt
# will read during the install is probed, and Freexian's key is checked against the
# pinned fingerprint, before the disk is touched. Needs gpg; else SKIP.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
trans=$repo/trans.sh
# shellcheck source=lib.sh
. "$repo/tests/lib.sh"

command -v gpg >/dev/null || skip "missing gpg"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

real_fpr=$(gen_key "$work/real" "Pinned Signer <pinned@example.invalid>")
gen_key "$work/evil" "Second Signer <second@example.invalid>" >/dev/null
for signer in real evil; do
    gpg --homedir "$work/$signer" --batch --export 2>/dev/null >"$work/$signer.gpg"
    printf 'Suite: bullseye\n' | gpg --homedir "$work/$signer" --batch --clearsign 2>/dev/null >"$work/InRelease.$signer"
done
cat "$work/real.gpg" "$work/evil.gpg" >"$work/both.gpg"

# trans.sh's collaborators, replaced: Freexian is two files, and wget --spider fails
# only for the URL in $work/missing.
cat >"$work/stubs.sh" <<STUBS
info() { :; }
apk() { :; }
error_and_exit() {
    echo "error_and_exit: \$*" >&2
    exit 1
}
download() {
    case "\$1" in
    */archive-key.gpg) cp "$work/served.gpg" "\$2" ;;
    */InRelease) cp "$work/served.InRelease" "\$2" ;;
    esac
}
wget() { [ "\$2" != "\$(cat "$work/missing")" ]; }
STUBS
for fn in import_verify_key is_signed_by get_debian_suites prepare_debian_sources; do
    extract_fn "$trans" "$fn"
done | sed -e "s|/tmp/verify|$work/verify|g" >"$work/fns.sh"

cat >"$work/case.sh" <<CASE
set -eE
. "$work/stubs.sh"
. "$work/fns.sh"
releasever=\$1
codename=\$2
freexian_key_url=https://freexian.invalid/archive-key.gpg
freexian_key_fpr=$real_fpr
apt_dir=$work/apt
prepare_debian_sources
CASE

# run <shell> <release> <codename> <served key> <InRelease signer> <missing URL>: prints
# the sources.list lines joined by " | ", or the error_and_exit reason.
run() {
    cp "$work/$4.gpg" "$work/served.gpg"
    cp "$work/InRelease.$5" "$work/served.InRelease"
    echo "$6" >"$work/missing"
    # shellcheck disable=SC2086
    if $1 "$work/case.sh" "$2" "$3" >/dev/null 2>"$work/log"; then
        paste -sd'|' "$work/apt/sources.list" | sed 's/|/ | /g'
    else
        sed -n 's/^error_and_exit: //p' "$work/log"
    fi
}

elts="https://deb.freexian.com/extended-lts"
freexian="[signed-by=/usr/share/keyrings/freexian-archive-extended-lts.gpg]"
debian="[signed-by=/usr/share/keyrings/debian-archive-keyring.gpg]"
d=https://deb.debian.org

for shell in "${shells[@]}"; do
    echo "== $shell: the suites apt reads during the install =="
    check "$shell / 10" "$(run "$shell" 10 buster real real -)" \
        "deb $freexian $elts buster main contrib non-free"
    check "$shell / 11" "$(run "$shell" 11 bullseye real real -)" \
        "deb $freexian $elts bullseye main contrib non-free"
    check "$shell / 13" "$(run "$shell" 13 trixie real real -)" \
        "deb $debian $d/debian trixie main non-free-firmware | deb $debian $d/debian trixie-updates main non-free-firmware | deb $debian $d/debian-security trixie-security main non-free-firmware"

    echo "== $shell: a suite that is gone stops the install before the disk is touched =="
    check "$shell / 13 without -updates" "$(run "$shell" 13 trixie real real "$d/debian/dists/trixie-updates/InRelease")" \
        "Debian trixie-updates is not available: $d/debian/dists/trixie-updates/InRelease"
    check "$shell / 11 without the suite" "$(run "$shell" 11 bullseye real real "$elts/dists/bullseye/InRelease")" \
        "Debian bullseye is not available: $elts/dists/bullseye/InRelease"

    echo "== $shell: Freexian's InRelease must be signed by the pinned key =="
    check "$shell / second key signs" "$(run "$shell" 11 bullseye both evil -)" \
        "Freexian bullseye InRelease is not signed by $real_fpr"
    check "$shell / signer missing from the key file" "$(run "$shell" 11 bullseye real evil -)" \
        "Freexian bullseye InRelease is not signed by $real_fpr"
    run "$shell" 11 bullseye both real - >/dev/null
    check "$shell / only the pinned key reaches the new system" \
        "$(gpg --batch --show-keys --with-colons "$work/apt/keyring.gpg" 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }')" "$real_fpr"
done

echo "== the sources are probed before the disk is touched =="
if extract_fn "$trans" trans | awk '
    $1 == "debian)" { in_arm = 1; next }
    in_arm && $1 == "prepare_debian_sources" { probe = NR }
    in_arm && $1 == "create_part" { part = NR }
    in_arm && $1 == ";;" { done = 1; exit !(probe && part && probe < part) }
    END { if (!done) exit 1 }'; then
    echo "    ok   debian: prepare_debian_sources precedes create_part"
else
    echo "    FAIL debian: prepare_debian_sources must run before create_part" >&2
    failures=$((failures + 1))
fi

finish
