#!/usr/bin/env bash
# ~/.bash/help.sh
#
# `cheatsheet` — the inventory of everything this setup adds to your shell.
#
# The descriptions are not maintained here.  They are read out of aliases.sh and
# functions.sh at the moment you ask for them, so the list cannot drift from the
# code: an alias without a description simply is not shipped (tests/unit.sh
# fails the build for it).  tools/gen-docs.sh reads the same records to build the
# README tables, so there is one source of truth rather than three.
#
# Two conventions produce a record:
#
#   alias NAME='body'    #: [tool] what it does     ← aliases.sh
#   # NAME [args] — what it does                    ← functions.sh, above the def
#
# The ` #: ` sigil is deliberate: a plain trailing `# note` stays a note for
# whoever is reading the source and never becomes a cheatsheet entry.
#
# NOTHING in this file runs at source time — it only defines two functions.
# This file is sourced by every interactive shell, so that property is load
# bearing, and tests/unit.sh enforces it by sourcing this file with no `awk`
# on PATH and requiring success.
# ─────────────────────────────────────────────────────────────────────────────

# _bc_help_parse FILE… — emit one TSV record per documented alias/function.
#
# Record: KIND \t SECTION \t NAME \t SIG-OR-EXPANSION \t REQUIRES \t DESCRIPTION
#
# POSIX awk only (no gensub/asort/intervals): mawk on Debian and BSD awk on
# macOS both have to run this.
_bc_help_parse() {
    awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

    # Offsets are computed with index()/length() rather than hardcoded, because
    # "── " is 3 characters to a UTF-8 awk and 7 bytes to a C-locale one.
    BEGIN { HDR = "── "; SIG = " #: "; DASH = " — " }

    # ── Section header: "# ── Title ─────…" ──────────────────────────────────
    substr($0, 1, 2) == "# " && index($0, HDR) == 3 {
        t = substr($0, index($0, HDR) + length(HDR))
        p = index(t, "─"); if (p > 0) t = substr(t, 1, p - 1)
        section = trim(t); nc = 0; next
    }

    # ── Alias: annotated with the " #: " sigil ───────────────────────────────
    /^[ \t]*alias[ \t]/ {
        nc = 0
        p = index($0, SIG); if (p == 0) next
        desc = trim(substr($0, p + length(SIG)))
        head = substr($0, 1, p - 1)
        sub(/^[ \t]*alias[ \t]+/, "", head)
        sub(/^--[ \t]+/, "", head)                 # alias -- -=...
        e = index(head, "="); if (e == 0) next
        name = substr(head, 1, e - 1)
        body = trim(substr(head, e + 1))
        q = substr(body, 1, 1)
        if (q == "\047" || q == "\"") body = substr(body, 2, length(body) - 2)
        emit("alias", name, body, desc)
        next
    }

    # ── Comment block, buffered for whatever function follows ────────────────
    /^[ \t]*#/ { cbuf[++nc] = $0; next }

    # ── Function: column-0 definitions only, so nested helpers like extract'"'"'s
    #    _need() are skipped without needing a rule of their own ─────────────
    /^[A-Za-z_][A-Za-z0-9_-]*\(\)[ \t]*\{/ {
        name = $0; sub(/\(\).*/, "", name)
        sig = ""; desc = ""
        for (i = 1; i <= nc; i++) {
            c = cbuf[i]; sub(/^#[ ]?/, "", c)
            # The first line of the block that names this function and carries
            # an em dash is the description; later lines are extended notes.
            if (substr(c, 1, length(name)) == name && index(c, DASH) > 0) {
                p    = index(c, DASH)
                sig  = trim(substr(c, length(name) + 1, p - length(name) - 1))
                desc = trim(substr(c, p + length(DASH)))
                break
            }
        }
        emit("func", name, sig, desc)
        nc = 0; next
    }

    { nc = 0 }

    # First ANNOTATED definition wins, so `ls` defined in both the eza and the
    # fallback branch yields exactly one record.
    function emit(kind, name, sig, desc,   req, p) {
        if (desc == "") return
        if ((kind SUBSEP name) in seen) return
        seen[kind SUBSEP name] = 1
        # functions.sh writes prose sentences and aliases.sh writes fragments;
        # dropping a trailing period lets both keep their natural style and
        # still line up in a table.
        sub(/\.$/, "", desc)
        req = ""
        if (substr(desc, 1, 1) == "[") {
            p = index(desc, "]")
            if (p > 1) { req = substr(desc, 2, p - 2); desc = trim(substr(desc, p + 1)) }
        }
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", kind, section, name, sig, req, desc
    }
    ' "$@"
}

# cheatsheet [filter] — list every alias and function, grouped by section.
#
# With no argument, prints everything.  With one, keeps only the rows whose
# section, name, expansion or description contain it (case-insensitively).
cheatsheet() {
    # The files to read are this file's own siblings, which is right in both
    # places it is used: ~/.bash when deployed, <repo>/bash when sourced by
    # tools/gen-docs.sh.  No configuration, no globals.
    local dir="${BASH_SOURCE[0]%/*}" f
    # `source help.sh` with no slash leaves the strip a no-op; then the siblings
    # are in the current directory.
    [[ "$dir" == "${BASH_SOURCE[0]}" ]] && dir='.'
    for f in aliases functions; do
        if [[ ! -r "${dir}/${f}.sh" ]]; then
            echo "cheatsheet: cannot read ${dir}/${f}.sh" >&2
            echo "            (run: bash setup.sh --skip-tools)" >&2
            return 1
        fi
    done

    local dim='' bold='' reset=''
    if [[ -t 1 ]]; then dim=$'\033[2m'; bold=$'\033[1m'; reset=$'\033[0m'; fi

    local records tool missing=''
    records="$(_bc_help_parse "${dir}/aliases.sh" "${dir}/functions.sh")"

    # Some entries only exist when an optional tool is installed.  Say so only
    # when it actually is not — on a machine that has docker, "(needs docker)"
    # on eleven rows is noise, and on a machine that does not, it is the answer
    # to why the command you just read about does nothing.
    while IFS= read -r tool; do
        [[ -n "$tool" ]] || continue
        command -v "$tool" &>/dev/null || missing="${missing}${tool},"
    done < <(printf '%s\n' "$records" | awk -F '\t' '$5 != "" { print $5 }' | sort -u)

    printf '%s\n' "$records" \
    | awk -F '\t' -v q="${1-}" -v dim="$dim" -v bold="$bold" -v rst="$reset" -v missing="$missing" '
        BEGIN { ql = tolower(q) }
        {
            # index() rather than a regex, so `cheatsheet [` is a search, not a
            # syntax error.
            if (ql != "" && index(tolower($2 " " $3 " " $4 " " $6), ql) == 0) next
            if ($2 != cur) { printf "\n%s%s%s\n", bold, $2, rst; cur = $2 }
            n++
            # Name, then what it does, then — dimmed and last, because it is the
            # column you read only when the description was not enough — what it
            # actually runs.  Long expansions push only that trailing column out
            # of alignment, never the description you are scanning.
            what = $6
            if ($5 != "" && index(missing, $5 ",") > 0) what = what " (needs " $5 ")"
            printf "  %-14s %-52s %s%s%s\n", $3, what, dim, $4, rst
        }
        END {
            if (n == 0) printf "no matches for \"%s\"\n", q
            else printf "\n"
        }
    '
}
