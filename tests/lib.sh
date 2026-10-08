# shellcheck shell=bash
# Sourced by the tests/check_*.sh harnesses. A harness reports through check and
# finish; its name in every message is its file name.

me=${0##*/}
me=${me%.sh}
failures=0

# extract_fn <file> <name>: prints function <name> from <file>, closing brace
# included; a nested definition is matched by its own indentation.
extract_fn() {
    awk -v name="$2" '
        !found && match($0, "^ *" name "\\(\\) \\{") {
            found = 1
            indent = substr($0, 1, index($0, name) - 1)
        }
        found { print }
        found && $0 == indent "}" { exit }
    ' "$1" | grep . || {
        echo "cannot extract $2() from ${1##*/}" >&2
        exit 2
    }
}

# check <label> <got> <want>
check() {
    if [ "$2" = "$3" ]; then
        echo "    ok   $1 = $2"
    else
        echo "    FAIL $1: expected '$3', got '$2'" >&2
        failures=$((failures + 1))
    fi
}

skip() {
    echo "SKIP $me: $1"
    exit 0
}

finish() {
    if [ "$failures" != 0 ]; then
        echo "$me: $failures assertion(s) failed" >&2
        exit 1
    fi
    echo "$me: ok"
    exit 0
}

# gen_key <homedir> <uid>: prints the fingerprint of a fresh signing key kept in <homedir>.
gen_key() {
    mkdir -p "$1"
    chmod 700 "$1"
    gpg --homedir "$1" --batch --pinentry-mode loopback --passphrase '' \
        --quick-gen-key "$2" ed25519 sign never >/dev/null 2>&1
    gpg --homedir "$1" --batch --with-colons --fingerprint 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }'
}

# trans.sh runs under busybox ash, so a harness of its functions runs them under
# that too when it is installed, after bash.
shells=(bash)
if busybox ash -c : 2>/dev/null; then
    shells+=("busybox ash")
fi
