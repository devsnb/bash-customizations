#!/usr/bin/env bash
# tests/integration/roundtrip.sh — full install → verify → uninstall → restore.
#
# Runs INSIDE a container (see Dockerfile); it mutates $HOME freely and is not
# safe to run on a real machine.  tests/docker.sh is the entry point.
#
# The cases are ordered as a story: a user installs, re-installs, previews an
# uninstall, mistypes a backup timestamp, then actually restores.  Each step
# asserts what the previous one promised.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "${REPO_DIR}/tests/lib/assert.sh"

if [[ "${ALLOW_HOME_MUTATION:-}" != "yes" ]]; then
    echo "refusing to run: this test rewrites \$HOME. Use tests/docker.sh." >&2
    exit 1
fi

ORIGINAL_BASHRC_MARKER="# ORIGINAL USER BASHRC — must survive a restore"
PRISTINE="$(mktemp)"

# home_hash — a fingerprint of everything setup.sh could touch, used to prove
# --dry-run changed nothing.
home_hash() {
    {
        find "$HOME" -maxdepth 3 \
             \( -path "$HOME/.cache" -o -path "$HOME/.bash_history" \) -prune -o \
             -printf '%p %y %s\n' 2>/dev/null | sort
        cat "$HOME/.bashrc" 2>/dev/null
    } | sha256sum | awk '{print $1}'
}

count_blocks() {
    # grep -c already prints 0 when there are no matches; the `|| true` is only
    # there to swallow its non-zero exit, not to print a second count.
    grep -cF "$1" "$HOME/.bashrc" 2>/dev/null || true
}

backup_count() {
    find "$HOME/.bash_backup" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

# ══════════════════════════════════════════════════════════════════════════════
suite "environment"
# ══════════════════════════════════════════════════════════════════════════════

echo "  HOME=${HOME}  uid=$(id -u)  sudo=$(command -v sudo >/dev/null && echo yes || echo no)"

# Seed a ~/.bashrc with a line that only the user's original file has.  Whether
# it comes back after a restore is the single most important assertion here.
printf '%s\n%s\n' "$ORIGINAL_BASHRC_MARKER" 'export MY_OWN_SETTING=42' > "$HOME/.bashrc"
chmod 644 "$HOME/.bashrc"
cp -a "$HOME/.bashrc" "$PRISTINE"

# ══════════════════════════════════════════════════════════════════════════════
suite "1. install"
# ══════════════════════════════════════════════════════════════════════════════

install_out=$(bash "${REPO_DIR}/setup.sh" 2>&1); install_rc=$?
if [[ $install_rc -ne 0 ]]; then
    echo "$install_out" | tail -30
fi
assert_eq "0" "$install_rc" "setup.sh completes successfully"
assert_not_contains "$install_out" "command not found" "setup.sh needs nothing beyond the documented prerequisites"

assert_exists "$HOME/.bash/aliases.sh"        "module symlinks are deployed"
assert_exists "$HOME/.config/starship.toml"   "starship.toml is deployed"
assert_file_contains "$HOME/.bashrc" "# === BEGIN bash-customizations ===" "HEAD block injected"
assert_file_contains "$HOME/.bashrc" "# === BEGIN bash-customizations-attach ===" "TAIL block injected"
assert_file_contains "$HOME/.bashrc" "$ORIGINAL_BASHRC_MARKER" "the user's own .bashrc content is preserved"

mode="$(stat -c '%a' "$HOME/.bashrc")"
assert_eq "644" "$mode" ".bashrc keeps its original permissions"

assert_exit 0 "doctor.sh reports a healthy setup" bash "${REPO_DIR}/doctor.sh"

# ══════════════════════════════════════════════════════════════════════════════
suite "2. a non-interactive shell stays silent"
# ══════════════════════════════════════════════════════════════════════════════

stderr_out=$(bash -c 'true' 2>&1 >/dev/null)
assert_eq "" "$stderr_out" "bash -c produces no stderr noise"

login_stderr=$(bash -lc 'true' 2>&1 >/dev/null)
assert_not_contains "$login_stderr" "module not found" "no missing-module warnings in a login shell"

# ══════════════════════════════════════════════════════════════════════════════
suite "3. re-running is idempotent"
# ══════════════════════════════════════════════════════════════════════════════

backups_before=$(backup_count)
assert_exit 0 "a second run succeeds" bash "${REPO_DIR}/setup.sh" --skip-tools

assert_eq "1" "$(count_blocks '# === BEGIN bash-customizations ===')" \
    "exactly one HEAD block after re-running"
assert_eq "1" "$(count_blocks '# === BEGIN bash-customizations-attach ===')" \
    "exactly one TAIL block after re-running"
assert_eq "$backups_before" "$(backup_count)" \
    "re-running creates no redundant backup"

# The manifest's BACKUP= is what --restore resolves to by default, so a re-run
# must not blank it — otherwise restore quietly degrades to "newest on disk".
manifest_backup=$(grep -m1 '^BACKUP=' "$HOME/.local/share/bash-customizations/manifest" | sed 's/^BACKUP=//')
if [[ -n "$manifest_backup" && -d "$manifest_backup" ]]; then
    _pass "the manifest still points at the original backup after a re-run"
else
    _fail "the manifest still points at the original backup after a re-run" \
          "BACKUP=${manifest_backup:-<empty>}"
fi
assert_exit 0 "doctor.sh still healthy after re-running" bash "${REPO_DIR}/doctor.sh"

# ══════════════════════════════════════════════════════════════════════════════
suite "4. --dry-run changes nothing"
# ══════════════════════════════════════════════════════════════════════════════

hash_before=$(home_hash)
bash "${REPO_DIR}/setup.sh" --dry-run >/dev/null 2>&1
assert_eq "$hash_before" "$(home_hash)" "setup.sh --dry-run leaves \$HOME untouched"

dry_out=$(bash "${REPO_DIR}/uninstall.sh" --dry-run 2>&1)
assert_eq "$hash_before" "$(home_hash)" "uninstall.sh --dry-run leaves \$HOME untouched"
assert_contains "$dry_out" "Would remove" "uninstall --dry-run describes what it would do"
assert_not_contains "$dry_out" "[OK]    Removed" "uninstall --dry-run never claims it removed anything"

# ══════════════════════════════════════════════════════════════════════════════
suite "5. refusing to act without a way to confirm"
# ══════════════════════════════════════════════════════════════════════════════

# No TTY and no --yes: the tool must fail loudly rather than print "Aborted."
# and exit 0, which is a failed run reporting success.
notty_rc=0
bash "${REPO_DIR}/uninstall.sh" </dev/null >/dev/null 2>&1 || notty_rc=$?
assert_eq "1" "$notty_rc" "uninstall without a TTY and without --yes exits 1"
assert_eq "$hash_before" "$(home_hash)" "…and changes nothing"

# ══════════════════════════════════════════════════════════════════════════════
suite "6. a mistyped backup timestamp is caught before anything is touched"
# ══════════════════════════════════════════════════════════════════════════════

bad_rc=0
bash "${REPO_DIR}/uninstall.sh" --restore=19700101_000000 --yes >/dev/null 2>&1 || bad_rc=$?
assert_eq "1" "$bad_rc" "a nonexistent backup timestamp exits 1"
assert_eq "$hash_before" "$(home_hash)" "…with the install left completely intact"
assert_exit 0 "doctor.sh confirms the setup is still healthy" bash "${REPO_DIR}/doctor.sh"

# ══════════════════════════════════════════════════════════════════════════════
suite "7. restore brings back the original ~/.bashrc"
# ══════════════════════════════════════════════════════════════════════════════

restore_out=$(bash "${REPO_DIR}/uninstall.sh" --restore --yes 2>&1); restore_rc=$?
if [[ $restore_rc -ne 0 ]]; then
    echo "$restore_out" | tail -20
fi
assert_eq "0" "$restore_rc" "uninstall --restore --yes succeeds"

# The whole point: byte-for-byte recovery of the file the tool cannot rebuild.
if diff -q "$PRISTINE" "$HOME/.bashrc" >/dev/null 2>&1; then
    _pass "~/.bashrc is restored byte-for-byte"
else
    _fail "~/.bashrc is restored byte-for-byte" \
          "diff: $(diff "$PRISTINE" "$HOME/.bashrc" | head -5 | tr '\n' ' ')"
fi
assert_not_contains "$(cat "$HOME/.bashrc")" "bash-customizations" \
    "no managed blocks survive the restore"
assert_absent "$HOME/.bash/aliases.sh" "module symlinks are gone"
assert_absent "$HOME/.config/starship.toml" "starship.toml symlink is gone"

assert_exit 1 "doctor.sh now reports the setup as absent" bash "${REPO_DIR}/doctor.sh"

# ══════════════════════════════════════════════════════════════════════════════
suite "8. plain uninstall (no restore) removes every trace"
# ══════════════════════════════════════════════════════════════════════════════

assert_exit 0 "re-install for the final case" bash "${REPO_DIR}/setup.sh" --skip-tools
assert_exit 0 "uninstall --yes succeeds" bash "${REPO_DIR}/uninstall.sh" --yes

assert_eq "0" "$(count_blocks '# === BEGIN bash-customizations ===')" "HEAD block removed"
assert_eq "0" "$(count_blocks '# === BEGIN bash-customizations-attach ===')" "TAIL block removed"
assert_absent "$HOME/.bash/exports.sh" "module symlinks removed"
assert_absent "$HOME/.local/share/bash-customizations/manifest" "manifest removed"
assert_file_contains "$HOME/.bashrc" "$ORIGINAL_BASHRC_MARKER" \
    "the user's own .bashrc content survives a plain uninstall"

# ══════════════════════════════════════════════════════════════════════════════
suite "9. backup housekeeping"
# ══════════════════════════════════════════════════════════════════════════════

list_out=$(bash "${REPO_DIR}/uninstall.sh" --list-backups 2>&1)
assert_not_contains "$list_out" '\033[' "--list-backups prints no literal escape codes"

prune_rc=0
bash "${REPO_DIR}/uninstall.sh" --prune-backups=1 --yes >/dev/null 2>&1 || prune_rc=$?
assert_eq "0" "$prune_rc" "--prune-backups succeeds"
kept=$(backup_count)
if [[ "$kept" -le 1 ]]; then
    _pass "--prune-backups keeps only the requested number (${kept})"
else
    _fail "--prune-backups keeps only the requested number" "kept ${kept} backups"
fi

finish
