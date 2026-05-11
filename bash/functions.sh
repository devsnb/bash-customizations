#!/usr/bin/env bash
# ~/.bash/functions.sh
#
# Shell utility functions.
# Keep each function focused and documented.
# ─────────────────────────────────────────────────────────────────────────────

# ── Navigation ────────────────────────────────────────────────────────────────

# mkcd — make a directory and cd into it in one step.
mkcd() {
    [[ $# -ne 1 ]] && { echo "Usage: mkcd <dir>" >&2; return 1; }
    mkdir -p -- "$1" && cd -- "$1" || return 1
}

# up [n] — go up n levels in the directory tree (default: 1).
up() {
    local count="${1:-1}"
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "up: expected a non-negative integer, got: '${count}'" >&2
        return 1
    fi
    local path=""
    for (( i = 0; i < count; i++ )); do
        path="${path}../"
    done
    cd "${path:-.}" || return 1
}

# ── File operations ───────────────────────────────────────────────────────────

# extract — auto-detect archive format and unpack it.
extract() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: extract <archive>" >&2
        return 1
    fi
    if [[ ! -f "$1" ]]; then
        echo "extract: '$1' is not a file" >&2
        return 1
    fi

    case "$1" in
        *.tar.bz2|*.tbz2) tar xjf "$1"     ;;
        *.tar.gz|*.tgz)   tar xzf "$1"     ;;
        *.tar.xz|*.txz)   tar xJf "$1"     ;;
        *.tar.zst) command -v unzstd &>/dev/null \
                    && tar --use-compress-program=unzstd -xf "$1" \
                    || { echo "extract: .tar.zst requires 'unzstd' (sudo apt install zstd)" >&2; return 1; } ;;
        *.tar)            tar xf  "$1"     ;;
        *.bz2)            bunzip2 "$1"     ;;
        *.gz)             gunzip  "$1"     ;;
        *.xz)             unxz    "$1"     ;;
        *.zip)            unzip   "$1"     ;;
        # unrar is proprietary freeware — not installed by setup.sh.
        # Alternatives: unar (open-source) or 7z with rar support.
        *.rar)  command -v unrar &>/dev/null \
                    && unrar x "$1" \
                    || { echo "extract: .rar requires 'unrar' (sudo apt install unrar)" >&2; return 1; } ;;
        *.7z)   command -v 7z &>/dev/null \
                    && 7z x "$1" \
                    || { echo "extract: .7z requires '7z' (sudo apt install p7zip-full)" >&2; return 1; } ;;
        *.Z)    command -v uncompress &>/dev/null \
                    && uncompress "$1" \
                    || { echo "extract: .Z requires 'uncompress' (sudo apt install ncompress)" >&2; return 1; } ;;
        *.zst)  command -v unzstd &>/dev/null \
                    && unzstd "$1" \
                    || { echo "extract: .zst requires 'unzstd' (sudo apt install zstd)" >&2; return 1; } ;;
        *)  echo "extract: '$1' — unknown or unsupported format" >&2; return 1 ;;
    esac
}

# bak — create a dated backup copy of a file.
bak() {
    [[ $# -ne 1 ]] && { echo "Usage: bak <file>" >&2; return 1; }
    cp -v -- "$1" "${1}.bak.$(date +%Y%m%d_%H%M%S)"
}

# ── Process / system ──────────────────────────────────────────────────────────

# port — show what process is listening on a given port.
port() {
    [[ $# -ne 1 ]] && { echo "Usage: port <number>" >&2; return 1; }
    if command -v ss &>/dev/null; then
        ss -tulpn | grep -E ":${1}([^0-9]|$)"
    elif command -v lsof &>/dev/null; then
        lsof -i ":$1"
    else
        echo "port: neither 'ss' nor 'lsof' found" >&2; return 1
    fi
}

# ── Text / search ─────────────────────────────────────────────────────────────

# find-in — recursive grep with a cleaner interface.
# Usage: find-in <pattern> [path]
find-in() {
    local pattern="${1:?Usage: find-in <pattern> [path]}"
    local search_path="${2:-.}"
    grep -rn --color=auto "$pattern" "$search_path"
}

# ── fzf helpers ───────────────────────────────────────────────────────────────

# fcd — fuzzy cd: interactively pick a directory with fzf.
fcd() {
    if ! command -v fzf &>/dev/null; then
        echo "fcd: fzf is not installed" >&2; return 1
    fi
    local dir fzf_exit
    dir=$(
        find "${1:-.}" -type d \
             -not -path '*/\.git/*' \
             -not -path '*/node_modules/*' \
             2>/dev/null \
        | fzf +m --preview="ls -la {}"
    ); fzf_exit=$?
    # fzf exits 130 when the user cancels (Esc / Ctrl-C) — that is not an error.
    [[ $fzf_exit -eq 130 ]] && return 0
    [[ $fzf_exit -ne 0 ]]   && return 1
    [[ -n "$dir" ]] && cd "$dir"
}

# fkill — interactively pick and kill a process.
fkill() {
    if ! command -v fzf &>/dev/null; then
        echo "fkill: fzf is not installed" >&2; return 1
    fi
    local pid ps_cmd
    # --no-headers is GNU procps (Linux); BSD ps (macOS) uses -h instead.
    if [[ "$OSTYPE" == darwin* ]]; then
        ps_cmd="ps -eo pid,ppid,comm -h"
    else
        ps_cmd="ps -eo pid,ppid,cmd --no-headers"
    fi
    pid=$(eval "$ps_cmd" \
        | fzf --header="Select process to kill" \
              --preview="echo {}" \
        | awk '{print $1}'
    )
    [[ -n "$pid" ]] && kill -"${1:-15}" "$pid" && echo "Sent signal ${1:-15} to PID $pid"
}

# ── Network ───────────────────────────────────────────────────────────────────

# myip — show public and local IP addresses.
myip() {
    echo -n "Public : "
    if command -v curl &>/dev/null; then
        curl -s --max-time 5 https://icanhazip.com || echo "(unavailable)"
    else
        echo "(curl not found)"
    fi
    echo -n "Local  : "
    if [[ "$OSTYPE" == darwin* ]]; then
        # macOS: hostname -I is not supported; use ipconfig or ifconfig
        ipconfig getifaddr en0 2>/dev/null \
            || ipconfig getifaddr en1 2>/dev/null \
            || ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127' | head -1 \
            || echo "(unavailable)"
    else
        hostname -I 2>/dev/null | awk '{print $1}' || echo "(unavailable)"
    fi
}

# ── Development ───────────────────────────────────────────────────────────────

# serve — start a simple HTTP server in the current directory.
serve() {
    local port="${1:-8000}"
    echo "Serving http://localhost:${port}  (Ctrl-C to stop)"
    if command -v python3 &>/dev/null; then
        python3 -m http.server "$port"
    elif command -v python &>/dev/null; then
        python -m http.server "$port"
    else
        echo "serve: Python not found" >&2; return 1
    fi
}

# ── Miscellaneous ─────────────────────────────────────────────────────────────

# reload — re-source ~/.bashrc without starting a new shell.
# NOTE: when ble.sh is active this triggers a second ble-attach, which can
# produce prompt glitches. If you see visual artifacts, open a fresh terminal.
reload() {
    # shellcheck source=/dev/null
    source "${HOME}/.bashrc" && echo "~/.bashrc reloaded."
}

# tre — tree with hidden files, colours, and pager.
tre() {
    if command -v tree &>/dev/null; then
        tree -aC -I '.git|node_modules|__pycache__|.venv' --dirsfirst "$@" | less -FRX
    else
        echo "tre: 'tree' is not installed" >&2; return 1
    fi
}

# weather — quick weather report for a location.
weather() {
    if ! command -v curl &>/dev/null; then
        echo "weather: curl is not installed" >&2; return 1
    fi
    local location="${1:-}"
    curl -s --max-time 10 "https://wttr.in/${location}?format=v2"
}
