#!/usr/bin/env bash
# tools/lock-tools.sh — write tools.lock: the pinned tool versions and hashes.
#
# setup.sh installs exactly what this file records and refuses anything whose
# SHA256 does not match.  That is the point: two machines set up months apart
# get the same shell, and a tampered or truncated download fails loudly instead
# of landing in ~/.local/bin.
#
# Usage:
#   bash tools/lock-tools.sh                 # re-hash the versions already pinned
#   bash tools/lock-tools.sh --latest        # move every tool to its newest release
#   bash tools/lock-tools.sh --check         # exit 1 if a newer release exists
#   bash tools/lock-tools.sh --latest fzf …  # move only the named tools
#
# Every hash is computed here, from the bytes actually downloaded, for all four
# platforms in BC_TOOL_PLATFORMS — not copied from a vendor's checksum file.
# A vendor checksum fetched at install time proves the download survived the
# CDN; a hash committed to git proves it is the same build that was reviewed.
#
# This needs the network and takes a minute: 4 tools x 4 platforms is 13
# downloads (ble.sh is one arch-independent tarball).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/log.sh
source "${REPO_DIR}/lib/log.sh"
# shellcheck source=../lib/tools.sh
source "${REPO_DIR}/lib/tools.sh"

LOCK="${REPO_DIR}/tools.lock"
ALL_TOOLS=("${BC_MANAGED_TOOLS[@]}")
TOOLS=("${ALL_TOOLS[@]}")

MODE='write'        # 'write' | 'check'
WANT_LATEST=false
SELECTED=()

for arg in "$@"; do
    case "$arg" in
        --latest) WANT_LATEST=true ;;
        --check)  MODE='check'; WANT_LATEST=true ;;
        -h|--help)
            sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) log_error "Unknown argument: $arg (use --help)"; exit 1 ;;
        *)  SELECTED+=("$arg") ;;
    esac
done

if [[ ${#SELECTED[@]} -gt 0 ]]; then
    for t in "${SELECTED[@]}"; do
        known=false
        for candidate in "${ALL_TOOLS[@]}"; do
            [[ "$candidate" == "$t" ]] && known=true
        done
        if ! $known; then
            log_error "Unknown tool: ${t}  (known: ${ALL_TOOLS[*]})"
            exit 1
        fi
    done
    # A check can restrict itself to named tools because it never writes.
    # A write must always emit every tool: named arguments select which
    # versions move, not which records survive in tools.lock.
    if [[ "$MODE" == 'check' ]]; then
        TOOLS=("${SELECTED[@]}")
    fi
fi

tool_selected() {
    [[ ${#SELECTED[@]} -eq 0 ]] && return 0
    local selected
    for selected in "${SELECTED[@]}"; do
        [[ "$selected" == "$1" ]] && return 0
    done
    return 1
}

command -v curl &>/dev/null || { log_error "curl is required."; exit 1; }
bc_sha256 /dev/null >/dev/null || { log_error "Need sha256sum or shasum."; exit 1; }

bc_tools_load || log_warn "No readable tools.lock yet — creating one."

# ── Discovering the newest release ────────────────────────────────────────────

# github_api PATH — query GitHub with stable headers and optional authentication.
# GITHUB_TOKEN/ GH_TOKEN raise the rate limit; neither value is ever printed.
github_api() {
    local path="$1" token="${GITHUB_TOKEN:-${GH_TOKEN:-}}" body detail err
    local -a args=(
        -sSfL --retry 3 --connect-timeout 20
        -H 'Accept: application/vnd.github+json'
        -H 'X-GitHub-Api-Version: 2022-11-28'
    )
    [[ -n "$token" ]] && args+=(-H "Authorization: Bearer ${token}")

    err="$(mktemp)"
    if ! body="$(curl "${args[@]}" "https://api.github.com${path}" 2>"$err")"; then
        detail="$(<"$err")"
        rm -f "$err"
        if [[ "$detail" == *'403'* || "$detail" == *'rate limit'* ]]; then
            log_error "GitHub API rate limit reached while requesting ${path}."
            log_error "  Set GITHUB_TOKEN or GH_TOKEN and try again."
        else
            log_error "GitHub API request failed for ${path}: ${detail:-unknown error}"
        fi
        return 1
    fi
    rm -f "$err"

    # GitHub can return a JSON error object through proxies that mask the HTTP
    # status.  Do not let its message get mistaken for an empty release field.
    if [[ "$body" == *'"message"'* && "$body" == *'rate limit'* ]]; then
        log_error "GitHub API rate limit reached while requesting ${path}."
        log_error "  Set GITHUB_TOKEN or GH_TOKEN and try again."
        return 1
    fi
    printf '%s\n' "$body"
}

json_release_tag() {
    if command -v python3 &>/dev/null; then
        python3 -c 'import json,sys; tag=json.load(sys.stdin)["tag_name"]; print(tag[1:] if tag.startswith("v") else tag)'
    else
        sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1
    fi
}

json_blesh_version() {
    if command -v python3 &>/dev/null; then
        python3 -c '
import json, re, sys
names = (asset.get("name", "") for asset in json.load(sys.stdin).get("assets", []))
versions = []
for name in names:
    match = re.fullmatch(r"ble-(nightly-[0-9]{8}\+[0-9a-f]+)\.tar\.xz", name)
    if match:
        versions.append(match.group(1))
if versions:
    print(max(versions))
'
    else
        grep -oE '"name"[[:space:]]*:[[:space:]]*"ble-nightly-[0-9]{8}\+[0-9a-f]+\.tar\.xz"' \
            | sed 's/.*"ble-\(.*\)\.tar\.xz"/\1/' | sort | tail -1
    fi
}

# latest_version TOOL — the newest published version, without a leading v.
latest_version() {
    local tool="$1" repo tag body
    case "$tool" in
        starship) repo=starship/starship   ;;
        fzf)      repo=junegunn/fzf        ;;
        zoxide)   repo=ajeetdsouza/zoxide  ;;
        blesh)
            # The nightly release's assets are the builds; the tag never moves.
            # Newest dated asset wins — ble-nightly.tar.xz itself is the rolling
            # pointer we are deliberately not pinning to.
            body="$(github_api '/repos/akinomyoga/ble.sh/releases/tags/nightly')" || return 1
            printf '%s\n' "$body" | json_blesh_version
            return ;;
    esac
    # Buffer the response rather than piping it: `grep -m1` closes the pipe as
    # soon as it matches, and curl then reports "(23) Failure writing output"
    # onto stderr for a request that in fact succeeded.
    body="$(github_api "/repos/${repo}/releases/latest")" || return 1
    tag="$(printf '%s\n' "$body" | json_release_tag)" || return 1
    printf '%s\n' "$tag"
}

# ── Build the new lock ────────────────────────────────────────────────────────

tmp="$(mktemp "${REPO_DIR}/.tools.lock.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

{
    echo "# tools.lock — the exact tool builds setup.sh installs."
    echo "#"
    echo "# Generated by tools/lock-tools.sh; do not edit by hand.  Every hash was"
    echo "# computed from the bytes actually downloaded, so changing a version means"
    echo "# re-running the generator, and a diff here is a real change in what lands"
    echo "# on your machine."
    echo "#"
    echo "#   make tools-outdated   see if anything newer has been released"
    echo "#   make tools-lock       re-hash the versions pinned below"
    echo "#   make tools-update     move everything to the newest release"
} > "$tmp"

status=0
outdated=()

for tool in "${TOOLS[@]}"; do
    current="$(bc_tool_version "$tool" 2>/dev/null || true)"

    if $WANT_LATEST && tool_selected "$tool"; then
        version="$(latest_version "$tool")"
        if [[ -z "$version" ]]; then
            log_error "${tool}: could not determine the newest release"
            status=1
            version="$current"
        fi
    else
        version="$current"
    fi

    if [[ -z "$version" ]]; then
        log_error "${tool}: no version pinned and --latest not given"
        status=1
        continue
    fi

    if [[ -n "$current" && "$current" != "$version" ]]; then
        outdated+=("${tool}: ${current} → ${version}")
    fi

    if [[ "$MODE" == 'check' ]]; then
        continue
    fi

    log_section "${tool} ${version}"

    {
        echo
        echo "${tool^^}_VERSION=${version}"
    } >> "$tmp"

    # ble.sh is one arch-independent tarball; the rest are per-platform binaries.
    if [[ "$tool" == blesh ]]; then
        platforms=(any)
    else
        platforms=("${BC_TOOL_PLATFORMS[@]}")
    fi

    for platform in "${platforms[@]}"; do
        url="$(bc_tool_url "$tool" "$platform" "$version")" || {
            log_error "${tool}: no URL for ${platform}"; status=1; continue; }

        blob="$(mktemp)"
        if ! curl -sSfL --retry 3 --connect-timeout 20 "$url" -o "$blob"; then
            log_error "${tool} ${platform}: download failed — ${url}"
            rm -f "$blob"; status=1; continue
        fi
        sha="$(bc_sha256 "$blob")"
        size="$(wc -c < "$blob" | tr -d ' ')"
        rm -f "$blob"

        if [[ "$tool" == blesh ]]; then
            echo "BLESH_SHA256=${sha}" >> "$tmp"
        else
            echo "${tool^^}_SHA256_${platform}=${sha}" >> "$tmp"
        fi
        log_ok "$(printf '%-16s %s  (%s bytes)' "$platform" "${sha:0:16}…" "$size")"
    done
done

# ── --check: report drift, write nothing ──────────────────────────────────────

if [[ "$MODE" == 'check' ]]; then
    echo
    if [[ ${#outdated[@]} -eq 0 ]]; then
        log_ok "Every pinned tool is at its newest release."
        exit "$status"
    fi
    log_warn "Newer releases are available:"
    printf '    %s\n' "${outdated[@]}"
    echo
    echo "  Move to them with:  make tools-update"
    exit 1
fi

if [[ "$status" -ne 0 ]]; then
    log_error "Something failed — tools.lock was NOT written."
    exit 1
fi

# Only a complete, fully-hashed run replaces the lock: a partial one would pin
# some tools and silently drop others.
chmod 644 "$tmp"
mv "$tmp" "$LOCK"
trap - EXIT

echo
log_ok "Wrote ${LOCK#"${REPO_DIR}/"}"
if [[ ${#outdated[@]} -gt 0 ]]; then
    printf '    %s\n' "${outdated[@]}"
fi
echo
echo "  Review the diff, then:  bash setup.sh --force  &&  bash doctor.sh"
