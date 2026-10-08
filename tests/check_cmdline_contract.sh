#!/bin/bash
# The stage 1 → stage 2 contract: only the keys in build_finalos_cmdline / build_extra_cmdline
# reach the kernel command line, and trans.sh reads them back under their bare names. A listed
# key trans.sh never reads is dead; a variable it reads but neither sets nor receives is empty.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
reinstall=$repo/reinstall.sh
trans=$repo/trans.sh
# shellcheck source=lib.sh
. "$repo/tests/lib.sh"

# The words of the `for key in …; do` list in one reinstall.sh function.
keys_of() {
    extract_fn "$reinstall" "$1" | tr '\n' ' ' |
        sed -n -E 's/.*for key in ([^;]*); do.*/\1/p' | sed 's/\\//g' | tr -s ' ' '\n' | grep . || {
        echo "no key list in $1()" >&2
        exit 2
    }
}

finalos_keys=$(keys_of build_finalos_cmdline)
extra_keys=$(keys_of build_extra_cmdline)
keys=$(printf '%s\n%s\n' "$finalos_keys" "$extra_keys" | LC_ALL=C sort -u)

# trans.sh without comments, single-quoted text (sed and awk programs) or escaped \$.
code=$(grep -v '^[[:space:]]*#' "$trans" | sed -E "s/'[^']*'//g; s/\\\\\\$//g")
reads=$(grep -oE '\$\{?[a-z_][a-z0-9_]*' <<<"$code" | sed -E 's/^\$\{?//' | LC_ALL=C sort -u)
# Set by trans.sh itself: plain assignments, read / local / for, and the eval targets
# of get_netconf_to / get_ra_to. An option such as --timezone= is not an assignment.
assigned=$({
    grep -oE '(^|[^a-zA-Z0-9_$-])[a-z_][a-z0-9_]*=' <<<"$code" | sed -E 's/^[^a-z_]//; s/=$//'
    grep -oE '\b(read|local|for)( -[a-z]+)*( [a-z_][a-z0-9_]*)+' <<<"$code" |
        tr ' ' '\n' | grep -vE '^(read|local|for|-[a-z]+)$'
    grep -oE '\bget_(netconf|ra)_to [a-z_][a-z0-9_]*' <<<"$code" | awk '{print $2}'
} | LC_ALL=C sort -u)

echo "== every key on the command line is read by trans.sh =="
for key in $keys; do
    check "$key" "$(grep -qx "$key" <<<"$reads" && echo read || echo unread)" read
done

echo "== trans.sh reads nothing that stage 1 does not send =="
unsent=$(LC_ALL=C comm -23 <(echo "$reads") <(echo "$assigned") | LC_ALL=C comm -23 - <(echo "$keys") | tr '\n' ' ')
check "read, never set, not in a key list" "${unsent% }" ""

finish
