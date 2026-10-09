#!/bin/bash
# Runs the trans.sh helpers that stand between a failure and the user. Under
# busybox ash a function that fails through `return N` stops the ERR trap after
# its first command, so a download that keeps failing must still reach
# error_and_exit; an anchor that matches nothing must stop the patch instead of
# landing on the wrong line; and the swap file must not depend on chattr +C.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
trans=$repo/trans.sh
reinstall=$repo/reinstall.sh
# shellcheck source=lib.sh
. "$repo/tests/lib.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The real error path (trap_err -> error_and_exit -> error), installed as trans.sh installs it.
for fn in error error_and_exit trap_err is_num retry insert_into_file create_swap; do
    extract_fn "$trans" "$fn"
done >"$work/fns.sh"

cat >"$work/case.sh" <<CASE
set -eE
. "$work/fns.sh"
trap 'trap_err \$LINENO \$?' ERR
fails_once() {
    [ -f "$work/once" ] && return 0
    touch "$work/once"
    return 3
}
chattr() { echo "chattr: Not supported" >&2; return 1; }
fallocate() { : >"\$3"; }
mkswap() { echo "mkswap \$*"; }
swapon() { echo "swapon \$*"; }
case \$1 in
retry_fails) retry 2 0 false ;;
retry_in_if) if retry 2 0 false; then echo "wrong branch"; else echo "fell back"; fi ;;
retry_recovers) retry 2 0 fails_once && echo "recovered" ;;
insert) echo NEW | insert_into_file "$work/file" "\$2" "\$3" ;;
swap) create_swap 64 "$work/swapfile" ;;
esac
echo "end"
CASE

# run_case <shell command> <args...>: sets rc, out and err.
run_case() {
    local shell=$1
    shift
    rm -f "$work/once"
    printf 'one\ntwo\nthree\n' >"$work/file"
    rc=0
    # shellcheck disable=SC2086
    $shell "$work/case.sh" "$@" >"$work/out" 2>"$work/err" || rc=$?
    out=$(cat "$work/out")
    err=$(cat "$work/err")
}

has() { grep -qF -- "$2" <<<"$1" && echo yes || echo no; }

for sh in "${shells[@]}"; do
    echo "[$sh]"

    run_case "$sh" retry_fails
    check "retry that keeps failing: exit" "$rc" 1
    check "retry that keeps failing: says to retry" "$(has "$err" "Run '/trans.sh' to retry.")" yes
    check "retry that keeps failing: stops there" "$(has "$out" end)" no

    run_case "$sh" retry_in_if
    check "retry inside if: takes the else branch" "$out" "fell back
end"
    check "retry inside if: exit" "$rc" 0

    run_case "$sh" retry_recovers
    check "retry that succeeds the second time" "$out" "recovered
end"

    run_case "$sh" insert after two
    check "insert after the one match" "$(tr '\n' ' ' <"$work/file")" "one two NEW three "
    run_case "$sh" insert before two
    check "insert before the one match" "$(tr '\n' ' ' <"$work/file")" "one NEW two three "

    run_case "$sh" insert after nine
    check "anchor matching nothing: exit" "$rc" 1
    check "anchor matching nothing: names it" "$(has "$err" "matching 'nine'")" yes
    check "anchor matching nothing: file untouched" "$(tr '\n' ' ' <"$work/file")" "one two three "

    run_case "$sh" insert before o
    check "anchor matching two lines: exit" "$rc" 1
    check "anchor matching two lines: file untouched" "$(tr '\n' ' ' <"$work/file")" "one two three "

    run_case "$sh" swap
    check "swap where chattr +C is unsupported: exit" "$rc" 0
    check "swap where chattr +C is unsupported: swapon" "$(has "$out" "swapon $work/swapfile")" yes
done

# reinstall.sh carries its own copy for patching the initramfs; it runs under bash only.
echo "[reinstall.sh]"
{
    echo 'error_and_exit() { echo "error: $*" >&2; exit 1; }'
    extract_fn "$reinstall" insert_into_file
} >"$work/fns1.sh"
cat >"$work/case1.sh" <<CASE
set -eE
. "$work/fns1.sh"
echo NEW | insert_into_file "$work/file" "\$1" "\$2"
CASE
for args in "after nine" "before nine" "after o"; do
    printf 'one\ntwo\nthree\n' >"$work/file"
    rc=0
    # shellcheck disable=SC2086
    bash "$work/case1.sh" $args 2>"$work/err" || rc=$?
    check "initramfs anchor '$args': exit" "$rc" 1
    check "initramfs anchor '$args': says why" "$(has "$(cat "$work/err")" "Expected exactly one line")" yes
    check "initramfs anchor '$args': file untouched" "$(tr '\n' ' ' <"$work/file")" "one two three "
done

finish
