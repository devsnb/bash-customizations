#!/usr/bin/env bash
# tools/gen-docs.sh — regenerate the README's alias and function tables.
#
# The tables used to be maintained by hand, and had drifted: the README still
# documented `fkill [signal]` after the signature became `fkill [-s SIG]
# [filter]`, and the alias section listed the git group as "gs, gl, gd, …".
# Now both tables are generated from the descriptions in bash/aliases.sh and
# bash/functions.sh — the same records `cheatsheet` prints — so there is one
# source of truth instead of three.
#
# Usage:
#   bash tools/gen-docs.sh              # rewrite README.md in place
#   bash tools/gen-docs.sh --check      # exit 1 (with a diff) if README is stale
#   bash tools/gen-docs.sh --stdout     # print the generated blocks and stop
#
# Only the regions between the markers are touched:
#
#   <!-- BEGIN GENERATED: aliases -->
#   <!-- END GENERATED: aliases -->
#
# Everything outside them passes through byte for byte, and a missing,
# duplicated or nested marker aborts before README.md is written at all.
#
# NOTE: README.md is rewritten by replacing it, so if you ever make it a symlink
# the link is what gets replaced.  It is a normal file in this repo.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="${REPO_DIR}/README.md"

# The parser lives in the module that ships to the user, so the shell command
# and these tables can never disagree about what is installed.
# shellcheck source=../bash/help.sh
source "${REPO_DIR}/bash/help.sh"

MODE=write
case "${1:-}" in
    ''|--write) MODE=write ;;
    --check)    MODE=check ;;
    --stdout)   MODE=stdout ;;
    -h|--help)
        sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "gen-docs: unknown argument: $1  (use --help)" >&2
        exit 1
        ;;
esac

# render KIND — turn the TSV record stream on stdin into a markdown section.
render() {
    awk -F '\t' -v want="$1" '
        # A pipe in a cell would split the table; psg expands to
        # "ps aux | grep -v grep | grep -i".
        function md(s) { gsub(/\|/, "\\|", s); return s }

        $1 != want { next }

        $2 != cur {
            printf "\n#### %s\n\n", $2
            cur = $2
            if (want == "alias") {
                print "| Alias | Expands to | Description |"
                print "|---|---|---|"
            } else {
                print "| Function | Description |"
                print "|---|---|"
            }
        }

        {
            d = md($6)
            if ($5 != "") d = d " *(requires `" $5 "`)*"
            if (want == "alias") printf "| `%s` | `%s` | %s |\n", md($3), md($4), d
            else                 printf "| `%s%s` | %s |\n", $3, ($4 != "" ? " " $4 : ""), d
        }
    '
}

# replace_block SRC ID BLOCK_FILE DEST — swap the marked region for BLOCK_FILE.
replace_block() {
    awk -v id="$2" -v block="$3" '
        $0 == "<!-- BEGIN GENERATED: " id " -->" {
            if (inblk) { bad = "nested BEGIN"; exit 3 }
            print; inblk = 1; nb++
            while ((getline line < block) > 0) print line
            close(block)
            next
        }
        $0 == "<!-- END GENERATED: " id " -->" {
            if (!inblk) { bad = "END before BEGIN"; exit 3 }
            inblk = 0; ne++
        }
        !inblk { print }
        END {
            if (bad) { print "gen-docs: " bad " for block: " id > "/dev/stderr"; exit 3 }
            if (nb != 1 || ne != 1) {
                printf "gen-docs: expected exactly one BEGIN/END pair for \"%s\" (found %d/%d)\n", \
                       id, nb, ne > "/dev/stderr"
                exit 3
            }
        }
    ' "$1" > "$4"
}

records="$(_bc_help_parse "${REPO_DIR}/bash/aliases.sh" "${REPO_DIR}/bash/functions.sh")"

# Temp files live inside the repo so the final mv is an atomic rename on the
# same filesystem rather than a copy that can be interrupted half-written.
tmp_alias="$(mktemp "${REPO_DIR}/.gen-alias.XXXXXX")"
tmp_func="$(mktemp "${REPO_DIR}/.gen-func.XXXXXX")"
tmp_a="$(mktemp "${REPO_DIR}/.README.a.XXXXXX")"
tmp_b="$(mktemp "${REPO_DIR}/.README.b.XXXXXX")"
trap 'rm -f "$tmp_alias" "$tmp_func" "$tmp_a" "$tmp_b"' EXIT

printf '%s\n' "$records" | render alias > "$tmp_alias"
printf '%s\n' "$records" | render func  > "$tmp_func"

if [[ "$MODE" == stdout ]]; then
    cat "$tmp_alias" "$tmp_func"
    exit 0
fi

replace_block "$README" aliases   "$tmp_alias" "$tmp_a"
replace_block "$tmp_a"  functions "$tmp_func"  "$tmp_b"

if [[ "$MODE" == check ]]; then
    if cmp -s "$tmp_b" "$README"; then
        echo "docs: README tables are up to date"
    else
        echo "docs: README tables are OUT OF DATE — run: make docs" >&2
        diff -u "$README" "$tmp_b" | head -60 >&2
        exit 1
    fi
    exit 0
fi

if cmp -s "$tmp_b" "$README"; then
    echo "docs: README tables already up to date"
else
    cp "$tmp_b" "$README"
    echo "docs: README tables regenerated"
fi
