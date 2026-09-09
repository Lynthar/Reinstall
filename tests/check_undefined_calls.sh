#!/bin/bash
# Fails when a script calls a function that nothing in the same file defines.
# Only names whose prefix ("get_", "is_", ...) is already used by a definition in
# that file are checked, so external commands are never mistaken for functions.
set -euo pipefail

# Function-shaped names that are provided from outside the script itself.
# Format: "<file>:<name>". Add an entry only with a comment saying who defines it.
allowlist=(
    # grub commands, inside a shell function that exists only so that
    # get_function_content can dump its body into grub.cfg as grub script.
    "reinstall.sh:load_env"
    "reinstall.sh:save_env"
)

# Emits "DEF <name>" and "CALL <name>" for one file.
# Here-doc bodies are skipped: they hold grub script and cloud-init YAML, not shell.
scan() {
    awk '
    function emit_calls(text, cont,    n, i, parts, w, rest) {
        gsub(/\$\(/, "\n", text)
        gsub(/`/, "\n", text)
        gsub(/&&|\|\||[;&|]/, "\n", text)
        n = split(text, parts, "\n")
        for (i = cont ? 2 : 1; i <= n; i++) {
            w = parts[i]
            sub(/^[[:space:]]+/, "", w)
            while (match(w, /^(if|then|elif|else|do|while|until|!|\{|\()[[:space:]]+/))
                w = substr(w, RLENGTH + 1)
            if (match(w, /^[A-Za-z_][A-Za-z0-9_]*/)) {
                rest = substr(w, RLENGTH + 1)
                if (rest == "" || rest ~ /^[[:space:]")}<>]/)
                    print "CALL " substr(w, 1, RLENGTH)
            }
        }
    }
    {
        line = $0
        if (delim != "") {
            probe = line
            sub(/^[[:space:]]+/, "", probe)
            sub(/[[:space:]]+$/, "", probe)
            if (probe == delim) delim = ""
            cont = 0
            next
        }
        if (line !~ /^[[:space:]]*#/) {
            if (match(line, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/)) {
                name = line
                sub(/^[[:space:]]*/, "", name)
                sub(/\(.*/, "", name)
                print "DEF " name
            }
            emit_calls(line, cont)
        }
        cont = (line ~ /\\$/)
        if (match(line, /<<-?[[:space:]]*'"'"'?"?[A-Za-z_][A-Za-z0-9_]*/) && line !~ /<<</) {
            delim = substr(line, RSTART, RLENGTH)
            sub(/^<<-?[[:space:]]*'"'"'?"?/, "", delim)
        }
    }
    ' "$1"
}

status=0
for f in "$@"; do
    scanned=$(scan "$f")
    defs=$(printf '%s\n' "$scanned" | sed -n 's/^DEF //p' | sort -u)
    [ -n "$defs" ] || continue
    prefixes=$(printf '%s\n' "$defs" | grep -Eo '^[a-z]+_' | sort -u | paste -sd'|' -)
    [ -n "$prefixes" ] || continue

    known=$defs
    for entry in "${allowlist[@]}"; do
        case "$entry" in
        "$f:"*) known=$(printf '%s\n%s' "$known" "${entry#*:}") ;;
        esac
    done

    missing=$(comm -23 \
        <(printf '%s\n' "$scanned" | sed -n 's/^CALL //p' | grep -E "^($prefixes)" | sort -u) \
        <(printf '%s\n' "$known" | sort -u))

    if [ -n "$missing" ]; then
        status=1
        for name in $missing; do
            echo "$f: calls '$name' but no definition exists" >&2
            grep -nE "(^|[^A-Za-z0-9_])$name([^A-Za-z0-9_(]|$)" "$f" | sed 's/^/    /' >&2
        done
    fi
done

if [ "$status" = 0 ]; then
    echo "check_undefined_calls: ok ($# file(s))"
fi
exit "$status"
