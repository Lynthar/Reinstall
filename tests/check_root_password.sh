#!/bin/bash
# Runs disable_root_password from trans.sh on shadow files in the states a cloud
# image or the Live OS leaves behind. With SSH keys the installed system must have
# no usable root password: an empty one lets the console and `su` in without asking,
# and `!` makes sshd without PAM (alpine) refuse the keys too, so it must be `*`.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
trans=$repo/trans.sh
# shellcheck source=lib.sh
. "$repo/tests/lib.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

extract_fn "$trans" disable_root_password >"$work/fns.sh"

cat >"$work/case.sh" <<CASE
set -eE
. "$work/fns.sh"
disable_root_password "$work/os"
CASE

for sh in "${shells[@]}"; do
    echo "[$sh]"
    for field in '' '!' '!*' '*' 'sha512-hash'; do
        mkdir -p "$work/os/etc"
        printf 'root:%s:20000:0:99999:7:::\ndaemon:*:20000:0:99999:7:::\nadmin:sha512-hash:20000:0:99999:7:::\n' \
            "$field" >"$work/os/etc/shadow"
        # shellcheck disable=SC2086
        $sh "$work/case.sh"
        check "root field '$field'" "$(grep '^root:' "$work/os/etc/shadow")" "root:*:20000:0:99999:7:::"
        check "root field '$field': other users untouched" "$(grep -v '^root:' "$work/os/etc/shadow" | tr '\n' ' ')" \
            'daemon:*:20000:0:99999:7::: admin:sha512-hash:20000:0:99999:7::: '
    done
done

finish
