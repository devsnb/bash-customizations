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
reference_modules=$(grep -oE '_src "\$HOME/\.bash/[a-z]+\.sh"' "${REPO_DIR}/.bashrc" | sed 's/.*bash\///; s/"//')
injected_modules=$(sed -n '/^_gen_head_block()/,/^CONTENT$/p' "${REPO_DIR}/setup.sh" \
    | grep -oE '_src "\$HOME/\.bash/[a-z]+\.sh"' | sed 's/.*bash\///; s/"//')

assert_eq "$reference_modules" "$injected_modules" \
    "reference .bashrc sources the same modules, in the same order, as the injected block"

module_count=$(printf '%s\n' "$injected_modules" | grep -c '\.sh')
assert_eq "8" "$module_count" "all 8 modules are sourced"

for module in $injected_modules; do
    assert_exists "${REPO_DIR}/bash/${module}" "module ${module} exists in the repo"
done

finish
