#!/bin/bash
# Runs dd_raw_with_extract from trans.sh against a wget that fails part-way. A raw
# image passes through cat, whose exit status is all a plain pipeline reports, so a
# truncated download must still fail. Also runs under busybox ash when installed.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
trans=$repo/trans.sh

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

# trans.sh's collaborators, replaced. wget plays the download end of the pipe: "ok"
# streams the whole image; "truncate" stops after 8 bytes with exit 4 (GNU wget:
# network failure); "missing" writes nothing and exits 8 (server error, e.g. 404).
cat >"$work/stubs.sh" <<'STUBS'
info() { :; }
apk() { :; }
error_and_exit() {
    echo "error_and_exit: $*" >&2
    exit 1
}
wget() {
    case "$wget_mode" in
    ok) cat "$image" ;;
    truncate)
        head -c 8 "$image"
        return 4
        ;;
    missing) return 8 ;;
    esac
}
STUBS
extract_fn pipe_extract >"$work/fns.sh"
extract_fn dd_raw_with_extract >>"$work/fns.sh"
printf 'raw image bytes, all of them' >"$work/image"

# The target disk is /dev/$xda; /dev/stdout lets the harness capture what was written.
cat >"$work/case.sh" <<CASE
set -eE
. "$work/stubs.sh"
. "$work/fns.sh"
xda=stdout
img=https://mirror.invalid/image.raw
img_type_warp=
image=$work/image
wget_mode=\$1
dd_raw_with_extract
CASE

failures=0
check() {
    if [ "$2" = "$3" ]; then
        echo "    ok   $1 = $2"
    else
        echo "    FAIL $1: expected '$3', got '$2'" >&2
        failures=$((failures + 1))
    fi
}

# run_case <shell command> <wget mode> <expected pass|fail>
run_case() {
    local shell=$1 mode=$2 want=$3 got
    # shellcheck disable=SC2086
    if $shell "$work/case.sh" "$mode" >"$work/disk" 2>"$work/log"; then
        got=pass
    else
        got=fail
    fi
    check "$shell / wget $mode" "$got" "$want"
}

shells=(bash)
if busybox ash -c : 2>/dev/null; then
    shells+=("busybox ash")
fi

for shell in "${shells[@]}"; do
    run_case "$shell" ok pass
    check "$shell / image written whole" "$(cmp -s "$work/disk" "$work/image" && echo yes || echo no)" yes
    run_case "$shell" truncate fail
    run_case "$shell" missing fail
done

if [ "$failures" != 0 ]; then
    echo "check_dd_pipeline: $failures assertion(s) failed" >&2
    exit 1
fi
echo "check_dd_pipeline: ok"
exit 0
