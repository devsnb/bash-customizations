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

# fcd prefers managed fd, and its portable fallback must prune dependency and
# repository metadata trees rather than merely hiding their output.
FCD_BIN="${WORK}/fcd-bin"
FCD_ROOT="${WORK}/fcd-root"
mkdir -p "$FCD_BIN" "$FCD_ROOT/target" "$FCD_ROOT/node_modules/deep" "$FCD_ROOT/.git/objects"
cat > "$FCD_BIN/fd" <<'FD'
#!/usr/bin/env bash
printf '%s\n' "$FCD_TARGET"
FD
cat > "$FCD_BIN/fzf" <<'FZF'
#!/usr/bin/env bash
selection=''
while IFS= read -r line; do
    printf '%s\n' "$line" >> "$FCD_LOG"
    [[ -n "$selection" ]] || selection="$line"
done
printf '%s\n' "$selection"
FZF
chmod +x "$FCD_BIN/fd" "$FCD_BIN/fzf"

out=$(
    export FCD_TARGET="$FCD_ROOT/target" FCD_LOG="${WORK}/fcd-fd.log"
    PATH="${FCD_BIN}:/usr/bin:/bin"
    source "${REPO_DIR}/bash/functions.sh"
    fcd "$FCD_ROOT" && pwd
)
assert_eq "$FCD_ROOT/target" "$out" "fcd uses fd output when fd is available"

rm "$FCD_BIN/fd"
out=$(
    export FCD_LOG="${WORK}/fcd-find.log"
    PATH="${FCD_BIN}:/usr/bin:/bin"
    source "${REPO_DIR}/bash/functions.sh"
    fcd "$FCD_ROOT" && pwd
)
assert_eq "$FCD_ROOT" "$out" "fcd retains a find fallback when fd is unavailable"
fallback_candidates="$(cat "${WORK}/fcd-find.log")"
assert_contains "$fallback_candidates" "$FCD_ROOT/target" "fcd fallback finds ordinary directories"
assert_not_contains "$fallback_candidates" "node_modules" "fcd fallback prunes node_modules"
assert_not_contains "$fallback_candidates" "/.git" "fcd fallback prunes .git"

# History stays bounded and avoids erasedups' full-history scan per command.
history_settings=$(bash --noprofile --norc -c \
    "source '${REPO_DIR}/bash/history.sh'; printf '%s %s %s' \"\$HISTSIZE\" \"\$HISTFILESIZE\" \"\$HISTCONTROL\"")
assert_eq "50000 100000 ignoreboth" "$history_settings" \
    "history uses bounded sizes and inexpensive duplicate filtering"

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

# The common formats used to be the UNguarded ones: `extract x.rar` coached you
# while `extract x.zip` died with a bare "unzip: command not found".  unzip,
# xz-utils and bzip2 are all absent from a minimal Debian install, so these are
# the branches most likely to be hit on a fresh machine.
BARE="$(sandbox_path "${WORK}/bare" bash)"
for fmt in zip:unzip bz2:bunzip2 xz:unxz gz:gunzip; do
    ext="${fmt%%:*}"; tool="${fmt##*:}"
    touch "${WORK}/sample.${ext}"
    out=$(
        source "${REPO_DIR}/bash/functions.sh"
        PATH="${BARE}"
        extract "${WORK}/sample.${ext}" 2>&1
    )
    assert_contains "$out" "requires '${tool}'" "extract names ${tool} for a .${ext}"
done

# GNU tar shells out to the compressor, so a box with tar but no bzip2 fails
# inside tar with a message that never mentions bzip2.  Name it ourselves.
TARONLY="$(sandbox_path "${WORK}/tar-only" bash tar)"
touch "${WORK}/sample.tar.bz2"
out=$(
    source "${REPO_DIR}/bash/functions.sh"
    PATH="${TARONLY}"
    extract "${WORK}/sample.tar.bz2" 2>&1
)
assert_contains "$out" "requires 'bzip2'" "extract names the compressor tar would have shelled out to"

# _need is defined inside extract and must not survive it — including on the
# failure paths, which used to `return` straight past the unset.
leaked=$(
    source "${REPO_DIR}/bash/functions.sh"
    PATH="${BARE}"
    extract "${WORK}/sample.zip" >/dev/null 2>&1
    declare -F _need >/dev/null && echo leaked
)
assert_eq "" "$leaked" "extract does not leak _need into the shell after a guard fails"

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
suite "bash/history.sh — incremental prompt sync"
# ══════════════════════════════════════════════════════════════════════════════

history_state=$(bash --noprofile --norc -c '
    PROMPT_COMMAND=(existing)
    source "$1/bash/history.sh"
    source "$1/bash/history.sh"
    printf "%s\n" "${PROMPT_COMMAND[@]}"
    declare -f _bc_history_sync
' _ "$REPO_DIR")
assert_eq "1" "$(printf '%s\n' "$history_state" | grep -cx '_bc_history_sync')" \
    "history hook is idempotent in array-form PROMPT_COMMAND"
assert_contains "$history_state" "history -n" "history sharing reads only newly appended entries"
assert_not_contains "$history_state" "history -c" "history sharing does not clear history every prompt"
assert_not_contains "$history_state" "history -r" "history sharing does not reread the full history file"

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

CAP_HOME="${WORK}/cap-home"
CAP_BIN="${WORK}/cap-bin"
mkdir -p "$CAP_HOME" "$CAP_BIN"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$CAP_BIN/eza"
chmod +x "$CAP_BIN/eza"
assert_exit 0 "setup can generate the runtime capability cache" \
    env HOME="$CAP_HOME" XDG_CACHE_HOME="$CAP_HOME/.cache" \
        PATH="$CAP_BIN:/usr/bin:/bin" bash --noprofile --norc -c \
        "source '${REPO_DIR}/setup.sh'; trap - ERR; write_capability_cache"
CAP_FILE="$CAP_HOME/.cache/bash-customizations/capabilities.sh"
assert_file_contains "$CAP_FILE" "BC_CAP_EZA=1" \
    "capability generation records an available optional tool"
assert_file_contains "$CAP_FILE" "BC_CAP_FD=0" \
    "capability generation records a missing tool"

# A cached negative answer must win over a live PATH search; otherwise absent
# WSL tools would still traverse every imported Windows directory at startup.
sed -i 's/^BC_CAP_EZA=1$/BC_CAP_EZA=0/' "$CAP_FILE"
cached_answer=$(env HOME="$CAP_HOME" XDG_CACHE_HOME="$CAP_HOME/.cache" \
    PATH="$CAP_BIN:/usr/bin:/bin" bash --noprofile --norc -c \
    "source '${REPO_DIR}/bash/exports.sh'; if _bc_has eza; then echo yes; else echo no; fi")
assert_eq "no" "$cached_answer" "runtime tool checks honour the setup cache"

# ══════════════════════════════════════════════════════════════════════════════
suite "script argument handling"
# ══════════════════════════════════════════════════════════════════════════════

repo_version="$(head -n1 "${REPO_DIR}/VERSION")"

for script in setup.sh doctor.sh uninstall.sh; do
    assert_exit 0 "${script} --help exits 0" bash "${REPO_DIR}/${script}" --help
    assert_exit 1 "${script} rejects an unknown flag" bash "${REPO_DIR}/${script}" --nope
    assert_exit 0 "${script} --version exits 0" bash "${REPO_DIR}/${script}" --version
    assert_contains "$(bash "${REPO_DIR}/${script}" --version 2>&1)" \
        "bash-customizations ${repo_version}" "${script} --version reports the repo version"
    assert_contains "$(bash "${REPO_DIR}/${script}" --help 2>&1)" \
        "--version" "${script} --help documents --version"
done

assert_exit 1 "setup.sh rejects the unverified legacy --latest path" \
    bash "${REPO_DIR}/setup.sh" --latest

# Everything downstream does `cat VERSION`; a stray second line would poison the
# tag comparison in CI with an error nobody could read.
assert_eq "1" "$(wc -l < "${REPO_DIR}/VERSION" | tr -d ' ')" \
    "VERSION is exactly one newline-terminated line"

semver=no
if [[ "$repo_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then semver=yes; fi
assert_eq "yes" "$semver" "VERSION is strict semver with no leading v (${repo_version})"

# One number in three places that can drift: the VERSION file, the newest
# CHANGELOG heading, and the git tag.
newest_entry="$(awk '/^## \[/ && !/^## \[Unreleased\]/ {
                       sub(/^## \[/, ""); sub(/\].*/, ""); print; exit }' "${REPO_DIR}/CHANGELOG.md")"
assert_eq "$repo_version" "$newest_entry" "the newest CHANGELOG release heading matches VERSION"

# The structure tools/release.sh rewrites; losing either turns cutting a release
# into a manual edit at exactly the wrong moment.
assert_file_contains "${REPO_DIR}/CHANGELOG.md" "## [Unreleased]" \
    "CHANGELOG keeps an Unreleased section"
assert_file_contains "${REPO_DIR}/CHANGELOG.md" "[Unreleased]:" \
    "CHANGELOG keeps the Unreleased link reference"

# The extractor the CI release job publishes with.
assert_contains "$(bash "${REPO_DIR}/tools/release.sh" --notes "$repo_version")" "###" \
    "release.sh --notes prints the newest section's body"
assert_exit 1 "release.sh --notes fails for a version the CHANGELOG lacks" \
    bash "${REPO_DIR}/tools/release.sh" --notes 99.99.99

# Argument validation runs before any git or make work, so these are instant and
# indifferent to whether the working tree is clean.  The full --dry-run is
# deliberately not tested here: it demands a clean tree on main, which someone
# running `make test-unit` mid-change does not have.
assert_exit 0 "release.sh --help exits 0" bash "${REPO_DIR}/tools/release.sh" --help
assert_exit 1 "release.sh refuses a version that is not semver" \
    bash "${REPO_DIR}/tools/release.sh" 1.2
assert_exit 1 "release.sh refuses a leading v" \
    bash "${REPO_DIR}/tools/release.sh" v1.2.3
assert_exit 1 "release.sh refuses no version at all" \
    bash "${REPO_DIR}/tools/release.sh"
assert_exit 1 "release.sh refuses two versions" \
    bash "${REPO_DIR}/tools/release.sh" 1.2.3 1.2.4

# A shallow clone or a tarball has no tags; only check when there are some.
if [[ -n "$(git -C "$REPO_DIR" tag --list 'v*' 2>/dev/null)" ]]; then
    nearest_tag="$(git -C "$REPO_DIR" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
    assert_eq "v${repo_version}" "$nearest_tag" "the newest reachable git tag matches VERSION"
fi

out=$(bash "${REPO_DIR}/doctor.sh" --help 2>&1)
assert_contains "$out" "warnings are advisory" "doctor --help documents its exit codes"
assert_contains "$out" "  14  " "doctor --help lists all 14 checks"
assert_not_contains "$out" "  15  " "doctor --help has no stale 15th check"

out=$(bash "${REPO_DIR}/uninstall.sh" --help 2>&1)
for flag in "--yes" "--restore-only" "--prune-backups" "--delete-backup" "--list-backups"; do
    assert_contains "$out" "$flag" "uninstall --help documents ${flag}"
done

out=$(bash "${REPO_DIR}/uninstall.sh" --prune-backups=abc 2>&1 || true)
assert_contains "$out" "expects a number" "uninstall validates --prune-backups=N"

for bad_selector in '../outside' 'nested/backup' '.' '' 'not-a-timestamp'; do
    assert_exit 1 "uninstall rejects unsafe backup selector '${bad_selector:-<empty>}'" \
        bash "${REPO_DIR}/uninstall.sh" "--delete-backup=${bad_selector}"
done
assert_exit 1 "restore rejects a backup path outside the backup root" \
    bash "${REPO_DIR}/uninstall.sh" --restore=../outside
assert_exit 1 "restore-only rejects an empty backup timestamp" \
    bash "${REPO_DIR}/uninstall.sh" --restore-only=
SELECTOR_HOME="${WORK}/selector-home"
mkdir -p "${SELECTOR_HOME}/.bash_backup" "${WORK}/outside-backup"
ln -s "${WORK}/outside-backup" "${SELECTOR_HOME}/.bash_backup/20000101_000000"
assert_exit 1 "restore rejects a timestamp-shaped symlink outside the backup root" \
    env HOME="$SELECTOR_HOME" bash "${REPO_DIR}/uninstall.sh" \
        --restore=20000101_000000 --yes

# ═════════════════════════════════════════════════════════════════════════════
suite "installer ownership and atomic replacement"
# ═════════════════════════════════════════════════════════════════════════════

# Dotfile recovery must not depend on the tool lock or any download path.  Use a
# deliberately incomplete copy (no tools.lock) so an accidental validation call
# cannot pass merely because the developer machine has everything installed.
SKIP_REPO="${WORK}/skip-repo"
mkdir -p "${SKIP_REPO}/lib" "${SKIP_REPO}/bash" "${WORK}/skip-home"
cp "${REPO_DIR}/setup.sh" "${REPO_DIR}/VERSION" \
   "${REPO_DIR}/.blerc" "${REPO_DIR}/starship.toml" "$SKIP_REPO/"
cp "${REPO_DIR}/lib/"*.sh "${SKIP_REPO}/lib/"
cp "${REPO_DIR}/bash/"*.sh "${SKIP_REPO}/bash/"
assert_exit 0 "--skip-tools works without tools.lock" \
    env HOME="${WORK}/skip-home" \
        XDG_CONFIG_HOME="${WORK}/skip-home/.config" \
        XDG_DATA_HOME="${WORK}/skip-home/.local/share" \
        XDG_CACHE_HOME="${WORK}/skip-home/.cache" \
        bash "${SKIP_REPO}/setup.sh" --skip-tools
assert_exists "${WORK}/skip-home/.cache/bash-customizations/capabilities.sh" \
    "--skip-tools still refreshes the runtime capability cache"

# A system fzf elsewhere on PATH must not suppress the pinned ~/.local/bin copy;
# a conflicting file at the managed path, however, needs explicit ownership.
DECISION_HOME="${WORK}/decision-home"
mkdir -p "${DECISION_HOME}/.local/bin" "${WORK}/system-bin"
printf '#!/usr/bin/env bash\necho "1.0.0"\n' > "${WORK}/system-bin/fzf"
chmod +x "${WORK}/system-bin/fzf"
decisions=$(HOME="$DECISION_HOME" PATH="${WORK}/system-bin:${PATH}" \
    bash --norc -c '
        source "$1/setup.sh"
        if binary_install_decision fzf 9.9.9 >/dev/null 2>&1; then echo -n 0; else echo -n $?; fi
        printf " "
        printf "#!/usr/bin/env bash\\necho 9.9.9\\n" > "$LOCAL_BIN/fzf"; chmod +x "$LOCAL_BIN/fzf"
        if binary_install_decision fzf 9.9.9 >/dev/null 2>&1; then echo -n 0; else echo -n $?; fi
        printf " "
        printf "#!/usr/bin/env bash\\necho 1.0.0\\n" > "$LOCAL_BIN/fzf"; chmod +x "$LOCAL_BIN/fzf"
        if binary_install_decision fzf 9.9.9 >/dev/null 2>&1; then echo -n 0; else echo -n $?; fi
        printf " "
        PREVIOUS_MANAGED_TOOLS=(fzf:1.0.0:0000000000000000000000000000000000000000000000000000000000000000)
        if binary_install_decision fzf 9.9.9 >/dev/null 2>&1; then echo -n 0; else echo -n $?; fi
        printf " "
        printf "#!/usr/bin/env bash\\necho 9.9.9\\n" > "$LOCAL_BIN/fzf"; chmod +x "$LOCAL_BIN/fzf"
        owned_sha="$(bc_sha256 "$LOCAL_BIN/fzf")"
        PREVIOUS_MANAGED_TOOLS=("fzf:9.9.9:${owned_sha}")
        if binary_install_decision fzf 9.9.9 >/dev/null 2>&1; then echo -n 0; else echo -n $?; fi
        printf " "
        printf "#!/usr/bin/env bash\\necho 9.9.9 # changed bytes\\n" > "$LOCAL_BIN/fzf"; chmod +x "$LOCAL_BIN/fzf"
        if binary_install_decision fzf 9.9.9 >/dev/null 2>&1; then echo -n 0; else echo -n $?; fi
    ' _ "$REPO_DIR")
assert_eq "0 2 2 0 1 0" "$decisions" \
    "install decisions distinguish PATH, ownership and changed bytes"

# Failed staging must not write through the live executable.
ATOMIC_HOME="${WORK}/atomic-home"
mkdir -p "${ATOMIC_HOME}/.local/bin" "${WORK}/empty-archive" "${WORK}/good-archive"
printf '#!/usr/bin/env bash\necho 1.0.0\n' > "${ATOMIC_HOME}/.local/bin/fzf"
chmod +x "${ATOMIC_HOME}/.local/bin/fzf"
tar -czf "${WORK}/missing-fzf.tar.gz" -C "${WORK}/empty-archive" .
printf '#!/usr/bin/env bash\necho 9.9.9\n' > "${WORK}/good-archive/fzf"
chmod +x "${WORK}/good-archive/fzf"
tar -czf "${WORK}/good-fzf.tar.gz" -C "${WORK}/good-archive" fzf

assert_exit 1 "a malformed archive fails before replacing the live binary" \
    env HOME="$ATOMIC_HOME" FIXTURE="${WORK}/missing-fzf.tar.gz" bash --norc -c '
        source "$1/setup.sh"
        fetch_verified() { cp "$FIXTURE" "$4"; }
        install_verified_binary fzf 9.9.9 linux_x86_64
    ' _ "$REPO_DIR"
assert_eq "1.0.0" "$("${ATOMIC_HOME}/.local/bin/fzf" --version)" \
    "a failed staged install preserves the previous binary"

assert_exit 0 "a validated staged binary is activated" \
    env HOME="$ATOMIC_HOME" FIXTURE="${WORK}/good-fzf.tar.gz" bash --norc -c '
        source "$1/setup.sh"
        fetch_verified() { cp "$FIXTURE" "$4"; }
        install_verified_binary fzf 9.9.9 linux_x86_64
    ' _ "$REPO_DIR"
assert_eq "9.9.9" "$("${ATOMIC_HOME}/.local/bin/fzf" --version)" \
    "atomic activation installs the expected version"

# fd is the one managed binary whose upstream archive nests the executable in
# a versioned target-triple directory.
FD_ATOMIC_HOME="${WORK}/fd-atomic-home"
FD_ARCHIVE_ROOT="${WORK}/fd-archive/fd-v9.9.9-x86_64-unknown-linux-musl"
mkdir -p "${FD_ATOMIC_HOME}/.local/bin" "$FD_ARCHIVE_ROOT"
printf '#!/usr/bin/env bash\necho "fd 9.9.9"\n' > "$FD_ARCHIVE_ROOT/fd"
chmod +x "$FD_ARCHIVE_ROOT/fd"
tar -czf "${WORK}/good-fd.tar.gz" -C "${WORK}/fd-archive" \
    fd-v9.9.9-x86_64-unknown-linux-musl
assert_exit 0 "fd is extracted from its nested release directory" \
    env HOME="$FD_ATOMIC_HOME" FIXTURE="${WORK}/good-fd.tar.gz" bash --norc -c '
        source "$1/setup.sh"
        fetch_verified() { cp "$FIXTURE" "$4"; }
        install_verified_binary fd 9.9.9 linux_x86_64
    ' _ "$REPO_DIR"
assert_eq "fd 9.9.9" "$("${FD_ATOMIC_HOME}/.local/bin/fd" --version)" \
    "the nested fd binary is activated at ~/.local/bin/fd"

# Purge follows TOOL records, not filenames.  fzf and ble.sh deliberately look
# managed but are absent from the fixture manifest and must survive.
PURGE_HOME="${WORK}/purge-home"
mkdir -p "${PURGE_HOME}/.local/bin" \
         "${PURGE_HOME}/.local/share/bash-customizations" \
         "${PURGE_HOME}/.local/share/blesh"
printf '#!/usr/bin/env bash\n' > "${PURGE_HOME}/.local/bin/starship"
printf '#!/usr/bin/env bash\n' > "${PURGE_HOME}/.local/bin/fzf"
printf '# user-owned ble.sh\n' > "${PURGE_HOME}/.local/share/blesh/ble.sh"
printf 'REPO=%s\nTOOL=starship:9.9.9:%064d\nTOOL=fzf:9.9.9\n' "$REPO_DIR" 0 \
    > "${PURGE_HOME}/.local/share/bash-customizations/manifest"
assert_exit 0 "tool purge succeeds with an ownership manifest" \
    env HOME="$PURGE_HOME" XDG_DATA_HOME="${PURGE_HOME}/.local/share" bash --norc -c '
        source "$1/uninstall.sh"
        ASSUME_YES=true
        read_manifest
        purge_tools
    ' _ "$REPO_DIR"
assert_absent "${PURGE_HOME}/.local/bin/starship" "purge removes an owned binary"
assert_exists "${PURGE_HOME}/.local/bin/fzf" "purge preserves an unowned same-name binary"
assert_exists "${PURGE_HOME}/.local/share/blesh/ble.sh" "purge preserves an unowned ble.sh directory"

# A plain uninstall leaves tools installed, so it must leave their ownership
# metadata too.  Otherwise the next setup rejects its own binary as unowned.
RETAIN_HOME="${WORK}/retain-home"
mkdir -p "${RETAIN_HOME}/.local/bin" "${RETAIN_HOME}/.local/share/bash-customizations"
printf '#!/usr/bin/env bash\necho "starship 9.9.9"\n' > "${RETAIN_HOME}/.local/bin/starship"
chmod +x "${RETAIN_HOME}/.local/bin/starship"
retain_sha="$(bash --norc -c 'source "$1/lib/tools.sh"; bc_sha256 "$2"' \
    _ "$REPO_DIR" "${RETAIN_HOME}/.local/bin/starship")"
printf 'REPO=%s\nVERSION=9.9.9\nTOOL=starship:9.9.9:%s\n' "$REPO_DIR" "$retain_sha" \
    > "${RETAIN_HOME}/.local/share/bash-customizations/manifest"
assert_exit 0 "plain uninstall succeeds while managed tools remain" \
    env HOME="$RETAIN_HOME" bash "${REPO_DIR}/uninstall.sh" --yes
assert_file_contains "${RETAIN_HOME}/.local/share/bash-customizations/manifest" \
    "TOOL=starship:9.9.9:${retain_sha}" "plain uninstall retains tool ownership"
decision=$(HOME="$RETAIN_HOME" bash --norc -c '
    source "$1/setup.sh"
    load_tool_ownership
    if binary_install_decision starship 9.9.9 >/dev/null; then echo 0; else echo $?; fi
' _ "$REPO_DIR")
assert_eq "1" "$decision" "a reinstall recognises the retained managed binary"

# Ownership checkpoints preserve the previous deployment records and make a
# newly activated tool recoverable even if a later installer aborts.
CHECKPOINT_HOME="${WORK}/checkpoint-home"
mkdir -p "${CHECKPOINT_HOME}/.local/share/bash-customizations"
printf 'REPO=%s\nLINK=%s/.bash/exports.sh\n' "$REPO_DIR" "$CHECKPOINT_HOME" \
    > "${CHECKPOINT_HOME}/.local/share/bash-customizations/manifest"
assert_exit 0 "tool ownership can be checkpointed before dotfile deployment" \
    env HOME="$CHECKPOINT_HOME" bash --norc -c '
        source "$1/setup.sh"
        MANAGED_TOOLS=(starship:9.9.9:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
        write_tool_ownership_checkpoint
    ' _ "$REPO_DIR"
assert_file_contains "${CHECKPOINT_HOME}/.local/share/bash-customizations/manifest" \
    "LINK=${CHECKPOINT_HOME}/.bash/exports.sh" "ownership checkpoint preserves existing links"
assert_file_contains "${CHECKPOINT_HOME}/.local/share/bash-customizations/manifest" \
    "TOOL=starship:9.9.9:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    "ownership checkpoint persists an activated tool"

FAIL_HOME="${WORK}/failed-install-home"
mkdir -p "$FAIL_HOME"
assert_exit 1 "a later installer failure still exits non-zero" \
    env HOME="$FAIL_HOME" bash --norc -c '
        source "$1/setup.sh"
        print_banner() { :; }
        check_prerequisites() { :; }
        ensure_locale() { :; }
        install_starship() {
            record_managed_tool starship 9.9.9 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        }
        install_blesh() { return 1; }
        main
    ' _ "$REPO_DIR"
assert_file_contains "${FAIL_HOME}/.local/share/bash-customizations/manifest" \
    "TOOL=starship:9.9.9:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    "a partial setup persists ownership before the next installer"

# Managed-block rewrites must preserve arbitrary user lines and reject damaged
# marker structure before touching the file.
REWRITE_DIR="${WORK}/rewrite"
mkdir -p "$REWRITE_DIR"
printf '%s\n' before '# === BEGIN bash-customizations ===' old \
    '# === END bash-customizations ===' -n after > "${REWRITE_DIR}/bashrc"
printf '%s\n' '# === BEGIN bash-customizations ===' new \
    '# === END bash-customizations ===' > "${REWRITE_DIR}/block"
assert_exit 0 "a valid managed block can be rewritten" bash --norc -c '
    source "$1/setup.sh"
    _rewrite_block "$2/bashrc" "$BLOCK_HEAD_BEGIN" "$BLOCK_HEAD_END" "$2/block"
' _ "$REPO_DIR" "$REWRITE_DIR"
assert_file_contains "${REWRITE_DIR}/bashrc" '-n' "bashrc rewrite preserves an echo option-like line"

printf '%s\n' before '# === BEGIN bash-customizations ===' old after > "${REWRITE_DIR}/malformed"
cp "${REWRITE_DIR}/malformed" "${REWRITE_DIR}/malformed.expected"
assert_exit 1 "setup refuses an unterminated managed block" bash --norc -c '
    source "$1/setup.sh"
    _rewrite_block "$2/malformed" "$BLOCK_HEAD_BEGIN" "$BLOCK_HEAD_END" "$2/block"
' _ "$REPO_DIR" "$REWRITE_DIR"
assert_exit 0 "refusing a malformed block leaves bashrc byte-for-byte intact" \
    cmp -s "${REWRITE_DIR}/malformed" "${REWRITE_DIR}/malformed.expected"
mkdir -p "${REWRITE_DIR}/uninstall-home"
cp "${REWRITE_DIR}/malformed" "${REWRITE_DIR}/uninstall-home/.bashrc"
assert_exit 1 "uninstall refuses an unterminated managed block" \
    env HOME="${REWRITE_DIR}/uninstall-home" bash --norc -c '
        source "$1/uninstall.sh"
        remove_bashrc_blocks
    ' _ "$REPO_DIR"
assert_exit 0 "uninstall leaves a malformed bashrc byte-for-byte intact" \
    cmp -s "${REWRITE_DIR}/uninstall-home/.bashrc" "${REWRITE_DIR}/malformed.expected"

assert_eq "0" "$(grep -cE 'make .*test-docker' "${REPO_DIR}/tools/release.sh" || true)" \
    "release checks do not invoke the Docker suite a second time"

# ═════════════════════════════════════════════════════════════════════════════
suite "tools.lock — completeness, platforms and verification"
# ═════════════════════════════════════════════════════════════════════════════

# shellcheck source=lib/tools.sh
source "${REPO_DIR}/lib/tools.sh"

assert_exit 0 "the committed lock contains every required version and hash" \
    bash -c "source '${REPO_DIR}/lib/tools.sh'; bc_tools_validate"

grep -v '^FZF_SHA256_linux_x86_64=' "${REPO_DIR}/tools.lock" > "${WORK}/incomplete.lock"
assert_exit 1 "lock validation rejects a missing platform hash" \
    bash -c "source '${REPO_DIR}/lib/tools.sh'; bc_tools_load '${WORK}/incomplete.lock'; bc_tools_validate"

assert_eq "5" "$(grep -cE '^[A-Z]+_VERSION=' "${REPO_DIR}/tools.lock")" \
    "the lock has one version for every managed tool"
assert_eq "9" "$(grep -cE '^[A-Z]+_SHA256(_[a-z0-9_]+)?=' "${REPO_DIR}/tools.lock")" \
    "the lock has eight Linux binary hashes plus the architecture-independent ble.sh hash"

for tool in "${BC_MANAGED_TOOLS[@]}"; do
    version="$(bc_tool_version "$tool")"
    if [[ "$tool" == blesh ]]; then
        platforms=(any)
    else
        platforms=("${BC_TOOL_PLATFORMS[@]}")
    fi
    for platform in "${platforms[@]}"; do
        url="$(bc_tool_url "$tool" "$platform" "$version")"
        assert_contains "$url" "https://github.com/" \
            "${tool}/${platform} resolves to a GitHub release asset"
    done
done

# Exercise the platform normalisation without depending on the CI host.
mkdir -p "${WORK}/fake-uname"
cat > "${WORK}/fake-uname/uname" <<'UNAME'
#!/usr/bin/env bash
case "$1" in
    -s) echo Linux ;;
    -m) echo arm64 ;;
    *) exit 1 ;;
esac
UNAME
chmod +x "${WORK}/fake-uname/uname"
assert_eq "linux_aarch64" "$(PATH="${WORK}/fake-uname:${PATH}" bc_tool_platform)" \
    "Linux arm64 is normalised to the lock's platform name"
assert_eq "aarch64-unknown-linux-musl" "$(_bc_tool_triple zoxide linux_aarch64)" \
    "the zoxide asset triple matches Linux ARM64"
assert_eq "x86_64-unknown-linux-musl" "$(_bc_tool_triple fd linux_x86_64)" \
    "the fd asset triple matches Linux x86_64"

mkdir -p "${WORK}/fake-darwin" "${WORK}/fake-i686"
printf '%s\n' '#!/usr/bin/env bash' \
    '[[ "$1" == -s ]] && echo Darwin || echo arm64' \
    > "${WORK}/fake-darwin/uname"
printf '%s\n' '#!/usr/bin/env bash' \
    '[[ "$1" == -s ]] && echo Linux || echo i686' \
    > "${WORK}/fake-i686/uname"
chmod +x "${WORK}/fake-darwin/uname" "${WORK}/fake-i686/uname"
assert_exit 1 "Darwin is not a supported platform" \
    env PATH="${WORK}/fake-darwin:${PATH}" bash -c \
        "source '${REPO_DIR}/lib/tools.sh'; bc_tool_platform"
assert_exit 1 "32-bit x86 is not a supported platform" \
    env PATH="${WORK}/fake-i686:${PATH}" bash -c \
        "source '${REPO_DIR}/lib/tools.sh'; bc_tool_platform"

mkdir -p "${WORK}/unsupported-home"
assert_exit 1 "setup rejects Darwin even when tool installation is skipped" \
    env HOME="${WORK}/unsupported-home" PATH="${WORK}/fake-darwin:${PATH}" \
        bash "${REPO_DIR}/setup.sh" --skip-tools
assert_exit 1 "unsupported setup exits before creating .bashrc" \
    test -e "${WORK}/unsupported-home/.bashrc"

# setup.sh is sourceable for focused tests but runs main only when executed.
# Stub the downloader so these assertions need no network.
printf 'wanted bytes' > "${WORK}/wanted-bytes"
wanted_sha="$(bc_sha256 "${WORK}/wanted-bytes")"
mismatch=$(
    source "${REPO_DIR}/setup.sh"
    trap - ERR
    download() { printf 'wrong bytes'; }
    BC_TOOLS[FZF_SHA256_linux_x86_64]="$wanted_sha"
    blob="${WORK}/checksum-mismatch"
    if fetch_verified fzf linux_x86_64 "$(bc_tool_version fzf)" "$blob" >/dev/null 2>&1; then
        echo accepted
    elif [[ -e "$blob" ]]; then
        echo rejected-but-left-file
    else
        echo rejected-and-removed
    fi
)
assert_eq "rejected-and-removed" "$mismatch" \
    "a checksum mismatch is rejected and its downloaded file is removed"

printf 'verified bytes' > "${WORK}/verified-bytes"
verified_sha="$(bc_sha256 "${WORK}/verified-bytes")"
verified=$(
    source "${REPO_DIR}/setup.sh"
    trap - ERR
    payload='verified bytes'
    download() { printf '%s' "$payload"; }
    BC_TOOLS[FZF_SHA256_linux_x86_64]="$verified_sha"
    blob="${WORK}/checksum-match"
    if fetch_verified fzf linux_x86_64 "$(bc_tool_version fzf)" "$blob" >/dev/null 2>&1 \
       && [[ "$(cat "$blob")" == "$payload" ]]; then
        echo verified
    else
        echo failed
    fi
)
assert_eq "verified" "$verified" "matching bytes pass checksum verification"

# Reproduce the dangerous partial-update case in a throwaway mini-repository.
# The named tool is the only version selected to move, but the rewritten lock
# must retain and re-hash every other tool as well.
LOCK_REPO="${WORK}/lock-repo"
mkdir -p "${LOCK_REPO}/lib" "${LOCK_REPO}/tools" "${LOCK_REPO}/stub-bin"
cp "${REPO_DIR}/lib/log.sh" "${REPO_DIR}/lib/tools.sh" "${LOCK_REPO}/lib/"
cp "${REPO_DIR}/tools.lock" "${LOCK_REPO}/tools.lock"
cp "${REPO_DIR}/tools/lock-tools.sh" "${LOCK_REPO}/tools/lock-tools.sh"
cat > "${LOCK_REPO}/stub-bin/curl" <<'CURL'
#!/usr/bin/env bash
url=''; output=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) shift; output="$1" ;;
        https://*) url="$1" ;;
    esac
    shift
done
[[ -n "$url" ]] || exit 1
if [[ -n "$output" ]]; then
    printf '%s\n' "$url" > "$output"
else
    printf '{"tag_name":"v99.0.0"}\n'
fi
CURL
chmod +x "${LOCK_REPO}/stub-bin/curl"

assert_exit 0 "a named lock refresh completes in the throwaway repository" \
    env PATH="${LOCK_REPO}/stub-bin:${PATH}" bash "${LOCK_REPO}/tools/lock-tools.sh" --latest fzf
assert_exit 0 "a named lock refresh preserves a complete, valid lock" \
    bash -c "source '${LOCK_REPO}/lib/tools.sh'; bc_tools_validate"
assert_file_contains "${LOCK_REPO}/tools.lock" "FZF_VERSION=99.0.0" \
    "a named update advances the selected tool"
assert_eq "5" "$(grep -cE '^[A-Z]+_VERSION=' "${LOCK_REPO}/tools.lock")" \
    "a named lock refresh does not drop unselected tool versions"
assert_eq "9" "$(grep -cE '^[A-Z]+_SHA256(_[a-z0-9_]+)?=' "${LOCK_REPO}/tools.lock")" \
    "a named lock refresh does not drop unselected platform hashes"

printf '%s\n' '#!/usr/bin/env bash' \
    'echo "curl: (22) The requested URL returned error: 403" >&2' \
    'exit 22' > "${LOCK_REPO}/stub-bin/curl"
chmod +x "${LOCK_REPO}/stub-bin/curl"
rate_out=$(env PATH="${LOCK_REPO}/stub-bin:${PATH}" \
    bash "${LOCK_REPO}/tools/lock-tools.sh" --check fzf 2>&1 || true)
assert_contains "$rate_out" "rate limit" "GitHub API 403s get a specific diagnostic"
assert_contains "$rate_out" "GITHUB_TOKEN" "the rate-limit diagnostic names the remedy"

for target in tools-lock tools-update tools-outdated; do
    assert_exit 0 "make ${target} is wired" make -s -n -C "$REPO_DIR" "$target"
done

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

# The module list is written out in SIX places.  The two above are compared to
# each other; the other four are fallbacks and check lists that only run when
# the manifest is missing, so a stale one stays invisible until the day someone
# actually needs it.  Adding or removing a module in a release means editing
# every one of them — this is what catches the one you forgot.
_module_set() { grep -oE '\.bash/[a-z_-]+\.sh' | sed 's|\.bash/||' | sort -u; }

repo_modules=$(find "${REPO_DIR}/bash" -maxdepth 1 -name '*.sh' -exec basename {} \; | sort)
assert_eq "$repo_modules" "$(printf '%s\n' "$injected_modules" | sort)" \
    "the injected block lists exactly the modules in bash/"

assert_eq "$repo_modules" \
    "$(sed -n '/_use_default_targets()/,/^}$/p' "${REPO_DIR}/uninstall.sh" | _module_set)" \
    "uninstall.sh's fallback target list is current"

assert_eq "$repo_modules" \
    "$(sed -n '/Fallback to the known list/,/^        )$/p' "${REPO_DIR}/doctor.sh" | _module_set)" \
    "doctor.sh's fallback symlink list is current"

assert_eq "$repo_modules" \
    "$(grep -oE 'for mod in [a-z_. -]+; do' "${REPO_DIR}/doctor.sh" \
       | sed 's/^for mod in //; s/; do$//' | tr ' ' '\n' | grep '\.sh$' | sort -u)" \
    "doctor.sh's load-order check covers every module"

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
# a plain trailing note stays legal.
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
