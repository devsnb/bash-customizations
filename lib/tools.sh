#!/usr/bin/env bash
# lib/tools.sh
#
# Everything the scripts know about the four tools setup.sh installs: which
# versions are pinned, what to download for a given platform, and how to check
# that what arrived is what was expected.
#
# SOURCED by setup.sh, doctor.sh and tools/lock-tools.sh, never executed.
#
# The pinned versions and hashes live in tools.lock at the repo root, not here.
# This file is the code that reads and uses them, exactly as lib/version.sh is
# the code that reads VERSION.  It lives apart from lib/log.sh for the same
# reason version.sh does: log.sh promises no side effects at source time, and
# reading a file is such a side effect.
#
# Adding a platform means adding its triples to _bc_tool_triple below AND its
# hashes to tools.lock (via `make tools-lock`).  Missing hashes are a hard
# failure at install time, never a silent skip — an unverified download is the
# thing this file exists to prevent.
# ─────────────────────────────────────────────────────────────────────────────

BC_TOOLS_LOCK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tools.lock"

# ── The lock file ─────────────────────────────────────────────────────────────

declare -gA BC_TOOLS=()
BC_MANAGED_TOOLS=(starship fzf zoxide blesh)

# bc_tools_load [FILE] — read tools.lock into BC_TOOLS.  Returns 1 if unreadable.
#
# Format is deliberately the dumbest thing that works: KEY=value, one per line,
# # comments and blanks ignored.  It is never sourced — a lock file is data, and
# `source`ing data downloaded or edited by anyone else is how data becomes code.
# shellcheck disable=SC2120  # tests and future callers may load a fixture path
bc_tools_load() {
    local file="${1:-$BC_TOOLS_LOCK}" line key value
    [[ -r "$file" ]] || return 1
    BC_TOOLS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"                      # tolerate a CRLF checkout
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "${line#"${line%%[![:space:]]*}"}" == '#'* ]] && continue
        [[ "$line" != *=* ]] && continue
        key="${line%%=*}"; value="${line#*=}"
        BC_TOOLS["$key"]="$value"
    done < "$file"
    [[ ${#BC_TOOLS[@]} -gt 0 ]]
}

# bc_tool_version TOOL — the pinned version, e.g. bc_tool_version starship
bc_tool_version() {
    local key="${1^^}_VERSION"
    [[ -n "${BC_TOOLS[$key]:-}" ]] || return 1
    printf '%s\n' "${BC_TOOLS[$key]}"
}

# bc_tool_sha TOOL PLATFORM — the pinned SHA256 for that platform's asset.
#
# ble.sh ships one arch-independent tarball of shell scripts, so it is keyed
# without a platform; everything else is a compiled binary and is not.
bc_tool_sha() {
    local tool="${1^^}" platform="$2" key
    if [[ "$tool" == "BLESH" ]]; then key="BLESH_SHA256"
    else                              key="${tool}_SHA256_${platform}"; fi
    [[ -n "${BC_TOOLS[$key]:-}" ]] || return 1
    printf '%s\n' "${BC_TOOLS[$key]}"
}

# ── Platforms ─────────────────────────────────────────────────────────────────

# bc_tool_platform — this machine, as "<os>_<arch>".  Returns 1 if unsupported.
#
# The names are normalised so the rest of the code sees one spelling for each
# of the two supported Linux architectures.
bc_tool_platform() {
    local os arch
    case "$(uname -s)" in
        Linux) os=linux ;;
        *)     return 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)   arch=x86_64  ;;
        aarch64|arm64)  arch=aarch64 ;;
        *)              return 1     ;;
    esac
    printf '%s_%s\n' "$os" "$arch"
}

# BC_TOOL_PLATFORMS — every platform tools.lock carries hashes for.
# tools/lock-tools.sh iterates this; tests/unit.sh asserts the lock covers it.
#
# shellcheck disable=SC2034
#   Consumed by tools/lock-tools.sh and tests/unit.sh, which shellcheck analyses
#   as separate units — the same reason lib/log.sh disables it for the palette.
BC_TOOL_PLATFORMS=(linux_x86_64 linux_aarch64)

# bc_tools_validate — require every managed version and platform hash.
# A malformed or partial lock must fail before setup downloads anything.
bc_tools_validate() {
    local tool platform version sha
    for tool in "${BC_MANAGED_TOOLS[@]}"; do
        version="$(bc_tool_version "$tool")" || return 1
        [[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z.+_-]*$ ]] || return 1

        if [[ "$tool" == blesh ]]; then
            sha="$(bc_tool_sha "$tool" any)" || return 1
            [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || return 1
            continue
        fi

        for platform in "${BC_TOOL_PLATFORMS[@]}"; do
            sha="$(bc_tool_sha "$tool" "$platform")" || return 1
            [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || return 1
        done
    done
}

# _bc_tool_triple TOOL PLATFORM — the vendor's name for that platform.
#
# Three projects, three naming schemes, none of them uname's.  starship and
# zoxide both use Rust target triples (and both publish musl builds for Linux,
# which is what we want — a glibc build breaks on Alpine and on older distros).
# fzf is Go and uses GOOS_GOARCH.
_bc_tool_triple() {
    case "$1:$2" in
        starship:linux_x86_64|zoxide:linux_x86_64)   echo x86_64-unknown-linux-musl  ;;
        starship:linux_aarch64|zoxide:linux_aarch64) echo aarch64-unknown-linux-musl ;;
        fzf:linux_x86_64)  echo linux_amd64 ;;
        fzf:linux_aarch64) echo linux_arm64 ;;
        *) return 1 ;;
    esac
}

# bc_tool_url TOOL PLATFORM VERSION — the exact asset to download.
bc_tool_url() {
    local tool="$1" platform="$2" version="$3" triple
    case "$tool" in
        blesh)
            # The nightly release keeps every dated build as its own immutable
            # asset beside the rolling ble-nightly.tar.xz.  Pinning to a dated
            # one keeps the nightly channel this setup deliberately tracks while
            # still naming a build that cannot change under us.
            printf 'https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-%s.tar.xz\n' "$version"
            ;;
        starship)
            triple="$(_bc_tool_triple starship "$platform")" || return 1
            printf 'https://github.com/starship/starship/releases/download/v%s/starship-%s.tar.gz\n' \
                   "$version" "$triple"
            ;;
        fzf)
            triple="$(_bc_tool_triple fzf "$platform")" || return 1
            printf 'https://github.com/junegunn/fzf/releases/download/v%s/fzf-%s-%s.tar.gz\n' \
                   "$version" "$version" "$triple"
            ;;
        zoxide)
            triple="$(_bc_tool_triple zoxide "$platform")" || return 1
            printf 'https://github.com/ajeetdsouza/zoxide/releases/download/v%s/zoxide-%s-%s.tar.gz\n' \
                   "$version" "$version" "$triple"
            ;;
        *) return 1 ;;
    esac
}

# ── Hashing ───────────────────────────────────────────────────────────────────

# bc_sha256 FILE — print the SHA256 of a file, or return 1 if nothing can.
#
# Linux distributions normally provide sha256sum; shasum is accepted as a
# compatible alternative.  Both print the hash as their first field.
bc_sha256() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        return 1
    fi
}

# ── Load on source ────────────────────────────────────────────────────────────
#
# Eager, like lib/version.sh reading VERSION, so callers can just ask for a
# version or a hash.  A missing or unreadable lock is tolerated here and turns
# into a specific error at the point of use ("tools.lock has no SHA256 for
# linux_aarch64"), which says far more than a failure to source would.
bc_tools_load || true
