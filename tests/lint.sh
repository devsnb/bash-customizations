#!/usr/bin/env bash
# tests/lint.sh — syntax check every script, then shellcheck if it is available.
#
# `bash -n` always runs: it needs nothing beyond bash itself and catches the
# class of typo that would break someone's shell.  shellcheck is reported as
# skipped rather than failing the run when it is not installed, so `make lint`
# stays useful on a bare machine; CI installs it and therefore enforces it.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || exit 1

status=0

mapfile -t SCRIPTS < <(
    printf '%s\n' setup.sh doctor.sh uninstall.sh
    printf '%s\n' bash/*.sh
    printf '%s\n' lib/*.sh
    printf '%s\n' tests/*.sh tests/lib/*.sh
    printf '%s\n' .bashrc .blerc
)

echo "── bash -n (${#SCRIPTS[@]} files)"
for f in "${SCRIPTS[@]}"; do
    [[ -f "$f" ]] || continue
    if bash -n "$f" 2>/tmp/lint-err.$$; then
        printf '  ok   %s\n' "$f"
    else
        printf '  FAIL %s\n' "$f"
        sed 's/^/       /' /tmp/lint-err.$$
        status=1
    fi
done
rm -f /tmp/lint-err.$$

echo
if ! command -v shellcheck &>/dev/null; then
    echo "── shellcheck: SKIPPED (not installed)"
    echo "   Install it for the full lint: sudo apt-get install -y shellcheck"
    exit "$status"
fi

echo "── shellcheck $(shellcheck --version | awk '/version:/{print $2}')"
# --severity=warning: fail on warnings and errors, print but tolerate `info`
# and `style` notes.  The remaining notes here are deliberate — literal
# single-quoted grep patterns (SC2016) and subshell-local variable changes in
# the tests (SC2030), where that isolation is the point of the test.
if shellcheck --severity=warning "${SCRIPTS[@]}"; then
    echo "  ok   no findings"
else
    status=1
fi

exit "$status"
