#!/usr/bin/env bash
# tests/unit.sh — behaviour tests for the shell modules and script arg parsing.
#
# No container required.  Everything here runs against the repo in place, in
# subshells, using a stub PATH when a test needs a command to be missing or to
# fail on demand.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/assert.sh
source "${REPO_DIR}/tests/lib/assert.sh"

# shellcheck disable=SC2030,SC2031  # every test runs in a subshell precisely so
# its PATH/EDITOR/OSTYPE changes stay local — that isolation is intentional
# shellcheck disable=SC2016  # the grep patterns are literal shell source text
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# sandbox_path DIR TOOL… — build a PATH containing ONLY the named tools.
#
# Testing "what happens when X is missing" needs a PATH where X genuinely is not
# found, while the tools the function itself relies on still are.  Symlinking a
# whitelist is the honest way to do that: `command -v X` then fails for real,
# exactly as it would on a machine without X.
sandbox_path() {
    local dir="$1"; shift
    mkdir -p "$dir"
    local tool resolved
    for tool in "$@"; do
        resolved="$(command -v "$tool" 2>/dev/null)" || continue
        ln -sf "$resolved" "${dir}/${tool}"
    done
    echo "$dir"
}

# ══════════════════════════════════════════════════════════════════════════════
suite "bash/functions.sh — navigation"
# ══════════════════════════════════════════════════════════════════════════════

out=$(
    source "${REPO_DIR}/bash/functions.sh"
    cd "$WORK" || exit 1
    mkdir -p a/b/c && cd a/b/c || exit 1
    up 2 && pwd
)
assert_eq "${WORK}/a" "$out" "up 2 climbs exactly two levels"

out=$(
    source "${REPO_DIR}/bash/functions.sh"
    up notanumber 2>&1
)
assert_contains "$out" "expected a non-negative integer" "up rejects a non-numeric argument"

assert_exit 1 "up returns 1 on a bad argument" \
    bash -c "source '${REPO_DIR}/bash/functions.sh'; up notanumber"

out=$(
    source "${REPO_DIR}/bash/functions.sh"
    cd "$WORK" || exit 1
    mkcd made-by-mkcd >/dev/null && pwd
)
assert_eq "${WORK}/made-by-mkcd" "$out" "mkcd creates the directory and enters it"

# ══════════════════════════════════════════════════════════════════════════════
suite "bash/functions.sh — extract"
# ══════════════════════════════════════════════════════════════════════════════

assert_exit 1 "extract rejects a missing file" \
    bash -c "source '${REPO_DIR}/bash/functions.sh'; extract /nonexistent.tar.gz"

touch "${WORK}/mystery.qqq"
out=$(
    source "${REPO_DIR}/bash/functions.sh"
    extract "${WORK}/mystery.qqq" 2>&1
)
assert_contains "$out" "unknown or unsupported format" "extract reports an unknown format"

# A missing helper must be named accurately…
touch "${WORK}/archive.rar"
NORAR="$(sandbox_path "${WORK}/no-unrar" tar gzip)"
out=$(
    source "${REPO_DIR}/bash/functions.sh"
    PATH="${NORAR}"
    extract "${WORK}/archive.rar" 2>&1
)
assert_contains "$out" "requires 'unrar'" "extract names the missing tool"

# …and a tool that EXISTS but fails must not be blamed as missing.
# gzip is in every base image; a truncated .gz makes it fail for real.
printf 'not actually gzip data' > "${WORK}/broken.gz"
out=$(
    source "${REPO_DIR}/bash/functions.sh"
    cd "$WORK" || exit 1
    extract "${WORK}/broken.gz" 2>&1
)
assert_not_contains "$out" "requires" "a failing extraction is not reported as a missing tool"

# ══════════════════════════════════════════════════════════════════════════════
suite "bash/functions.sh — myip / port / fkill"
# ══════════════════════════════════════════════════════════════════════════════

# No hostname on PATH: the local-IP lookup must degrade, not print a blank.
NOHOST="$(sandbox_path "${WORK}/no-hostname" awk sed)"
out=$(
    source "${REPO_DIR}/bash/functions.sh"
    PATH="${NOHOST}"
    OSTYPE="linux-gnu"
    myip 2>/dev/null | sed -n 's/^Local  : //p'
)
assert_eq "(unavailable)" "$out" "myip falls back when hostname fails"

# A PATH with grep but deliberately without ss or lsof.
NONET="$(sandbox_path "${WORK}/no-net-tools" grep)"
out=$(
    source "${REPO_DIR}/bash/functions.sh"
    PATH="${NONET}"
    port 8080 2>&1
)
assert_contains "$out" "neither 'ss' nor 'lsof'" "port reports missing tooling"

NOFZF="$(sandbox_path "${WORK}/no-fzf" ps awk grep)"
out=$(
    source "${REPO_DIR}/bash/functions.sh"
    PATH="${NOFZF}"
    fkill -s 9 nginx 2>&1
)
assert_contains "$out" "fzf is not installed" "fkill -s parses without treating the filter as a signal"

# ══════════════════════════════════════════════════════════════════════════════
suite "bash/exports.sh + bash/aliases.sh"
# ══════════════════════════════════════════════════════════════════════════════

out=$(
    unset EDITOR VISUAL
    source "${REPO_DIR}/bash/exports.sh" >/dev/null 2>&1
    echo "${EDITOR}:${VISUAL}"
)
assert_eq "nano:nano" "$out" "EDITOR/VISUAL default to nano"

out=$(
    EDITOR="vim"
    source "${REPO_DIR}/bash/exports.sh" >/dev/null 2>&1
    echo "$EDITOR"
)
assert_eq "vim" "$out" "a pre-set EDITOR is respected"

out=$(
    source "${REPO_DIR}/bash/aliases.sh" >/dev/null 2>&1
    alias ll 2>/dev/null
)
assert_contains "$out" "alias ll=" "aliases.sh defines ll on this host"

# ══════════════════════════════════════════════════════════════════════════════
suite "script argument handling"
# ══════════════════════════════════════════════════════════════════════════════

for script in setup.sh doctor.sh uninstall.sh; do
    assert_exit 0 "${script} --help exits 0" bash "${REPO_DIR}/${script}" --help
    assert_exit 1 "${script} rejects an unknown flag" bash "${REPO_DIR}/${script}" --nope
done

out=$(bash "${REPO_DIR}/doctor.sh" --help 2>&1)
assert_contains "$out" "warnings are advisory" "doctor --help documents its exit codes"
assert_contains "$out" "  12  " "doctor --help lists all 12 checks"
assert_not_contains "$out" "  13  " "doctor --help has no stale 13th check"

out=$(bash "${REPO_DIR}/uninstall.sh" --help 2>&1)
for flag in "--yes" "--restore-only" "--prune-backups" "--delete-backup" "--list-backups"; do
    assert_contains "$out" "$flag" "uninstall --help documents ${flag}"
done

out=$(bash "${REPO_DIR}/uninstall.sh" --prune-backups=abc 2>&1 || true)
assert_contains "$out" "expects a number" "uninstall validates --prune-backups=N"

# ══════════════════════════════════════════════════════════════════════════════
suite "the reference .bashrc matches what setup.sh injects"
# ══════════════════════════════════════════════════════════════════════════════

# .bashrc is documented as usable standalone, so its module list and order must
# stay identical to the block setup.sh writes into the user's real ~/.bashrc.
# Nothing else keeps these two copies honest.
reference_modules=$(grep -oE '_src "\$HOME/\.bash/[a-z_-]+\.sh"' "${REPO_DIR}/.bashrc" | sed 's/.*bash\///; s/"//')
injected_modules=$(sed -n '/^_gen_head_block()/,/^CONTENT$/p' "${REPO_DIR}/setup.sh" \
    | grep -oE '_src "\$HOME/\.bash/[a-z_-]+\.sh"' | sed 's/.*bash\///; s/"//')

assert_eq "$reference_modules" "$injected_modules" \
    "reference .bashrc sources the same modules, in the same order, as the injected block"

module_count=$(printf '%s\n' "$injected_modules" | grep -c '\.sh')
assert_eq "9" "$module_count" "all 9 modules are sourced"

for module in $injected_modules; do
    assert_exists "${REPO_DIR}/bash/${module}" "module ${module} exists in the repo"
done

# ══════════════════════════════════════════════════════════════════════════════
suite "bash/help.sh — the cheatsheet parser"
# ══════════════════════════════════════════════════════════════════════════════

# ── Hygiene: this file is sourced by EVERY interactive shell ─────────────────

# The load-bearing one.  Sourcing help.sh must do no work at all — if anyone
# ever moves the parsing to source time, this fails immediately because the
# sandbox has no awk.
assert_exit 0 "help.sh sources with no awk on PATH (nothing parses at source time)" \
    bash --norc -c "PATH='$(sandbox_path "${WORK}/noawk" bash cat)'; source '${REPO_DIR}/bash/help.sh'"

defined=$(bash --norc -c "source '${REPO_DIR}/bash/help.sh'; compgen -A function | grep -E '^(cheatsheet|_bc_)' | sort | tr '\n' ' '")
assert_eq "_bc_help_parse cheatsheet " "$defined" "help.sh defines exactly two functions"

leaked=$(bash --norc -c "source '${REPO_DIR}/bash/help.sh'; compgen -v | grep -E '^_?[Bb][Cc]_' | tr '\n' ' '")
assert_eq "" "$leaked" "help.sh leaks no globals into the shell"

# ── Parser semantics, against a fixture covering every awkward shape ─────────

cat > "${WORK}/fx.sh" <<'FIXTURE'
# ── First section ─────────────────────────────────────────────────────────────
alias plain='echo hi'          #: a plain entry
alias noted='echo hi'          # just a note, not a description
alias -- -='cd -'              #: the dash alias
alias piped='ps aux | grep -i' #: an expansion containing a pipe
if command -v eza &>/dev/null; then
    alias dup='eza'            #: the annotated definition
else
    alias dup='ls'
fi
alias gated='eza --tree'       #: [eza] only with eza installed
FIXTURE

cat > "${WORK}/fxfn.sh" <<'FIXTURE'
# ── Second section ────────────────────────────────────────────────────────────
# multi <arg> — the first line is the description.
#
# Everything below the blank comment is an extended note and must be ignored,
# including this sentence which contains — an em dash.
multi() {
    _nested() { echo "indented helpers must not become entries"; }
    _nested
}
FIXTURE

records=$(bash --norc -c "source '${REPO_DIR}/bash/help.sh'; _bc_help_parse '${WORK}/fx.sh' '${WORK}/fxfn.sh'")
field() { printf '%s\n' "$records" | awk -F '\t' -v n="$1" -v f="$2" '$3 == n { print $f }'; }

assert_eq "a plain entry"  "$(field plain 6)"  "an annotated alias is parsed"
assert_eq ""               "$(field noted 6)"  "a plain # comment is a note, not a description"
assert_eq "cd -"           "$(field - 4)"      "alias -- - is parsed as the name '-'"
assert_eq "ps aux | grep -i" "$(field piped 4)" "a pipe in the expansion survives intact"
assert_eq "1" "$(printf '%s\n' "$records" | awk -F '\t' '$3 == "dup"' | wc -l)" \
    "a name defined in both branches yields exactly one record"
assert_eq "the annotated definition" "$(field dup 6)" "the annotated definition is the one kept"
assert_eq "eza" "$(field gated 5)" "a [tool] prefix becomes the requires field"
assert_eq "only with eza installed" "$(field gated 6)" "…and is stripped from the description"
assert_eq "First section" "$(field plain 2)" "the section header becomes the group"

assert_eq "<arg>" "$(field multi 4)" "a function's argument spec is parsed"
assert_eq "the first line is the description" "$(field multi 6)" \
    "only the first line of a multi-line function comment is used"
assert_eq "" "$(field _nested 6)" "an indented nested helper is not an entry"

# ── Completeness: an undocumented alias must not be shippable ────────────────

# Deliberately a second, dumber extractor.  If the parser had a bug that dropped
# entries, comparing it against itself would prove nothing.
defined_aliases=$(grep -E '^[[:space:]]*alias[[:space:]]' "${REPO_DIR}/bash/aliases.sh" \
    | sed -E 's/^[[:space:]]*alias[[:space:]]+//; s/^--[[:space:]]+//; s/=.*//' | sort -u)
documented_aliases=$(bash --norc -c "source '${REPO_DIR}/bash/help.sh'; _bc_help_parse '${REPO_DIR}/bash/aliases.sh'" | cut -f3 | sort -u)
assert_eq "$defined_aliases" "$documented_aliases" \
    "every alias in aliases.sh carries a #: description"

annotation_count=$(grep -cE '^[[:space:]]*alias[[:space:]].* #: ' "${REPO_DIR}/bash/aliases.sh")
assert_eq "$(printf '%s\n' "$documented_aliases" | wc -l)" "$annotation_count" \
    "no alias name is annotated twice"

# The parser splits on the FIRST ' #: ', so a '#' inside an expansion would
# truncate it silently.  Forbid that outright rather than handle it.
# Everything left of the sigil on an annotated line is the definition; a '#'
# in there means the expansion contains one.  Unannotated lines are skipped so
# a plain trailing "# BSD/macOS" note stays legal.
stray_hash=$(grep -E '^[[:space:]]*alias[[:space:]].* #: ' "${REPO_DIR}/bash/aliases.sh" \
    | sed 's/ #: .*//' | grep '#' || true)
assert_eq "" "$stray_hash" "no alias expansion contains a literal #"

defined_funcs=$(grep -oE '^[A-Za-z_][A-Za-z0-9_-]*\(\)' "${REPO_DIR}/bash/functions.sh" | sed 's/()//' | sort)
documented_funcs=$(bash --norc -c "source '${REPO_DIR}/bash/help.sh'; _bc_help_parse '${REPO_DIR}/bash/functions.sh'" | cut -f3 | sort)
assert_eq "$defined_funcs" "$documented_funcs" \
    "every function in functions.sh carries a — description"

# ── cheatsheet works from the deployed copy, with no repo present ────────────

mkdir -p "${WORK}/fakebash"
cp "${REPO_DIR}/bash/aliases.sh" "${REPO_DIR}/bash/functions.sh" "${REPO_DIR}/bash/help.sh" "${WORK}/fakebash/"
sheet=$(bash --norc -c "source '${WORK}/fakebash/help.sh'; cheatsheet git")
assert_contains "$sheet" "gds" "cheatsheet resolves its sources as siblings, not via the repo"
assert_not_contains "$sheet" "dkps" "a filter excludes non-matching entries"
assert_contains "$(bash --norc -c "source '${WORK}/fakebash/help.sh'; cheatsheet zzzznope")" \
    "no matches" "an unmatched filter says so instead of printing nothing"

# ── The README tables are generated from the same records ───────────────────

# Also asserted by `make docs-check`; duplicated here so a bare `make test-unit`
# catches a stale README too.
assert_exit 0 "the README alias/function tables are up to date (else: make docs)" \
    bash "${REPO_DIR}/tools/gen-docs.sh" --check

# A backtick in an expansion would break the code span the table wraps it in.
assert_eq "" "$(grep -E '^[[:space:]]*alias[[:space:]].* #: ' "${REPO_DIR}/bash/aliases.sh" | sed 's/ #: .*//' | grep '`' || true)" \
    "no alias expansion contains a backtick"

finish
