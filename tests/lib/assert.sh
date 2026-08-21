#!/usr/bin/env bash
# tests/lib/assert.sh
#
# Minimal assertion helpers.  Deliberately dependency-free — the repo installs
# no test framework, and a test suite that needs its own install step is a test
# suite people stop running.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
#   assert_eq "expected" "$actual" "what this proves"
#   ...
#   finish            # prints the tally and exits 0/1
# ─────────────────────────────────────────────────────────────────────────────

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_SUITE=""

if [[ -t 1 ]]; then
    _T_GREEN='\033[0;32m'; _T_RED='\033[0;31m'; _T_DIM='\033[2m'; _T_BOLD='\033[1m'
    _T_RESET='\033[0m'
else
    _T_GREEN=''; _T_RED=''; _T_DIM=''; _T_BOLD=''; _T_RESET=''
fi

suite() {
    CURRENT_SUITE="$1"
    printf '\n%b%s%b\n' "${_T_BOLD}" "── $1" "${_T_RESET}"
}

_pass() {
    (( TESTS_RUN++ )) || true
    printf '  %bok%b   %s\n' "${_T_GREEN}" "${_T_RESET}" "$1"
}

_fail() {
    (( TESTS_RUN++ )) || true
    (( TESTS_FAILED++ )) || true
    printf '  %bFAIL%b %s%s\n' "${_T_RED}" "${_T_RESET}" \
        "${CURRENT_SUITE:+[${CURRENT_SUITE}] }" "$1"
    local detail
    for detail in "${@:2}"; do
        printf '       %b%s%b\n' "${_T_DIM}" "$detail" "${_T_RESET}"
    done
}

# assert_eq EXPECTED ACTUAL MESSAGE
assert_eq() {
    if [[ "$1" == "$2" ]]; then
        _pass "$3"
    else
        _fail "$3" "expected: $1" "actual:   $2"
    fi
}

# assert_contains HAYSTACK NEEDLE MESSAGE
assert_contains() {
    if [[ "$1" == *"$2"* ]]; then
        _pass "$3"
    else
        _fail "$3" "expected to contain: $2" "actual: ${1:0:400}"
    fi
}

# assert_not_contains HAYSTACK NEEDLE MESSAGE
assert_not_contains() {
    if [[ "$1" != *"$2"* ]]; then
        _pass "$3"
    else
        _fail "$3" "expected NOT to contain: $2" "actual: ${1:0:400}"
    fi
}

# assert_exit EXPECTED_CODE MESSAGE CMD [args…]
assert_exit() {
    local expected="$1" message="$2"; shift 2
    local actual=0
    "$@" >/dev/null 2>&1 || actual=$?
    if [[ "$actual" -eq "$expected" ]]; then
        _pass "$message"
    else
        _fail "$message" "expected exit ${expected}, got ${actual}" "command: $*"
    fi
}

# assert_file_contains FILE NEEDLE MESSAGE
assert_file_contains() {
    if [[ -f "$1" ]] && grep -qF -- "$2" "$1"; then
        _pass "$3"
    else
        _fail "$3" "file: $1" "expected to contain: $2"
    fi
}

# assert_exists PATH MESSAGE  /  assert_absent PATH MESSAGE
assert_exists() {
    if [[ -e "$1" || -L "$1" ]]; then _pass "$2"; else _fail "$2" "missing: $1"; fi
}
assert_absent() {
    if [[ ! -e "$1" && ! -L "$1" ]]; then _pass "$2"; else _fail "$2" "still present: $1"; fi
}

# finish — print the tally, exit 0 when everything passed.
finish() {
    echo
    if [[ "$TESTS_FAILED" -eq 0 ]]; then
        printf '%b%d passed%b\n' "${_T_GREEN}${_T_BOLD}" "$TESTS_RUN" "${_T_RESET}"
        exit 0
    fi
    printf '%b%d of %d failed%b\n' "${_T_RED}${_T_BOLD}" "$TESTS_FAILED" "$TESTS_RUN" "${_T_RESET}"
    exit 1
}
