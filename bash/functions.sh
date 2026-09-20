#!/usr/bin/env bash
# ~/.bash/functions.sh
#
# Shell utility functions.
# Keep each function focused and documented.
# ─────────────────────────────────────────────────────────────────────────────

# ── Navigation ────────────────────────────────────────────────────────────────

# mkcd <dir> — make a directory and cd into it in one step.
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

# extract <archive> — auto-detect archive format and unpack it.
extract() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: extract <archive>" >&2
        return 1
    fi
    if [[ ! -f "$1" ]]; then
        echo "extract: '$1' is not a file" >&2
        return 1
    fi

    # _need ARCHIVE HINT TOOL… — fail early, and accurately, when a tool is absent.
    # Chaining `command -v X && action || echo "needs X"` used to blame a missing
    # tool whenever the extraction itself failed (corrupt archive, bad path).
    #
    # Takes several tools because the tar branches need two: GNU tar shells out
    # to the compressor, so `tar xjf` on a box without bzip2 fails inside tar
    # with a message that never names bzip2.
    _need() {
        local archive="$1" hint="$2"; shift 2
        local tool
        for tool in "$@"; do
            command -v "$tool" &>/dev/null && continue
            echo "extract: '${archive}' requires '${tool}' (${hint})" >&2
            return 1
        done
    }

    # Every branch is guarded.  The exotic formats were guarded from the start
    # and the common ones were not, which meant `extract x.rar` coached you
    # while `extract x.zip` died with a bare "unzip: command not found" — and
    # unzip, xz-utils and bzip2 are all absent from a minimal Debian install.
    case "$1" in
        *.tar.bz2|*.tbz2) _need "$1" "sudo apt install tar bzip2" tar bzip2 \
                              && tar xjf "$1" ;;
        *.tar.gz|*.tgz)   _need "$1" "sudo apt install tar gzip"  tar gzip  \
                              && tar xzf "$1" ;;
        *.tar.xz|*.txz)   _need "$1" "sudo apt install tar xz-utils" tar xz \
                              && tar xJf "$1" ;;
        *.tar.zst)        _need "$1" "sudo apt install tar zstd" tar unzstd \
                              && tar --use-compress-program=unzstd -xf "$1" ;;
        *.tar)            _need "$1" "sudo apt install tar" tar \
                              && tar xf "$1" ;;
        # NOTE: bunzip2/gunzip/unxz replace the archive with its contents —
        # unlike the .tar.* cases, the original file does not survive.
        *.bz2)            _need "$1" "sudo apt install bzip2" bunzip2 \
                              && bunzip2 "$1" ;;
        *.gz)             _need "$1" "sudo apt install gzip" gunzip \
                              && gunzip "$1" ;;
        *.xz)             _need "$1" "sudo apt install xz-utils" unxz \
                              && unxz "$1" ;;
        *.zip)            _need "$1" "sudo apt install unzip" unzip \
                              && unzip "$1" ;;
        # unrar is proprietary freeware — not installed by setup.sh.
        # Alternatives: unar (open-source) or 7z with rar support.
        *.rar)            _need "$1" "sudo apt install unrar" unrar \
                              && unrar x "$1" ;;
        *.7z)             _need "$1" "sudo apt install p7zip-full" 7z \
                              && 7z x "$1" ;;
        *.Z)              _need "$1" "sudo apt install ncompress" uncompress \
                              && uncompress "$1" ;;
        *.zst)            _need "$1" "sudo apt install zstd" unzstd \
                              && unzstd "$1" ;;
        # `false` rather than `return 1`: a return here would skip the unset
        # below and leak _need into the caller's shell.
        *)  echo "extract: '$1' — unknown or unsupported format" >&2; false ;;
    esac

    # $? is the matched branch's exit status.  Capture it before unset -f, which
    # would otherwise overwrite it with its own.
    local rc=$?
    unset -f _need
    return "$rc"
}

# backup-file <file> — create a dated backup copy of a file.
backup-file() {
    [[ $# -ne 1 ]] && { echo "Usage: backup-file <file>" >&2; return 1; }
    cp -v -- "$1" "${1}.bak.$(date +%Y%m%d_%H%M%S)"
}

# ── Process / system ──────────────────────────────────────────────────────────

# port <number> — show what process is listening on a given port.
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

# ports — list every listening port and the process behind it.
#
# Was an alias for `ss -tulpn`, which simply does not exist on macOS.  Sharing
# `port`'s fallback keeps the two consistent: whatever tool answers `port 8080`
# is the one that answers `ports`.
ports() {
    if command -v ss &>/dev/null; then
        ss -tulpn
    elif command -v lsof &>/dev/null; then
        lsof -nP -iTCP -sTCP:LISTEN
    else
        echo "ports: neither 'ss' nor 'lsof' found" >&2; return 1
    fi
}

# ── Text / search ─────────────────────────────────────────────────────────────

# grep-in <pattern> [path] — recursive grep with a cleaner interface.
grep-in() {
    local pattern="${1:?Usage: grep-in <pattern> [path]}"
    local search_path="${2:-.}"
    grep -rn --color=auto "$pattern" "$search_path"
}

# ── fzf helpers ───────────────────────────────────────────────────────────────

# fcd [dir] — [fzf] fuzzy cd: interactively pick a directory with fzf.
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
    [[ -n "$dir" ]] && cd "$dir" || return 1
}

# fkill [-s SIGNAL] [filter] — [fzf] interactively pick a process and kill it.
#
# The optional argument is a name filter, which is what you actually reach for
# ("fkill node").  The signal moved behind -s: it used to be the first
# positional argument, so the natural `fkill nginx` expanded to `kill -nginx`.
fkill() {
    if ! command -v fzf &>/dev/null; then
        echo "fkill: fzf is not installed" >&2; return 1
    fi

    local signal=15
    if [[ "${1:-}" == "-s" ]]; then
        if [[ -z "${2:-}" ]]; then
            echo "Usage: fkill [-s SIGNAL] [filter]" >&2; return 1
        fi
        signal="$2"; shift 2
    fi
    local filter="${1:-}"

    local -a ps_cmd
    # --no-headers is GNU procps (Linux); BSD ps (macOS) uses -h instead.
    # shellcheck disable=SC2054  # the commas belong to ps's -o format, they are
    #                              not array element separators
    if [[ "$OSTYPE" == darwin* ]]; then
        ps_cmd=(ps -eo pid,ppid,comm -h)
    else
        ps_cmd=(ps -eo pid,ppid,cmd --no-headers)
    fi

    local selection pid
    selection=$("${ps_cmd[@]}" \
        | fzf --query="$filter" \
              --header="Select a process to kill (signal ${signal})" \
              --preview="echo {}" \
        | awk '{print $1}'
    )
    [[ -z "$selection" ]] && return 0

    pid="$selection"
    # Killing is irreversible and the list is one keystroke deep — confirm the
    # actual target rather than trusting the highlight.
    local name
    name="$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")"
    read -r -p "Send signal ${signal} to PID ${pid} (${name})? [y/N] " reply
    [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]] || { echo "Cancelled."; return 0; }

    kill -"$signal" "$pid" && echo "Sent signal ${signal} to PID ${pid} (${name})"
}

# ── Network ───────────────────────────────────────────────────────────────────

# myip — [curl] show public and local IP addresses.
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
        # A pipeline's exit status is the LAST command's, so `cmd | awk || echo`
        # never reached the fallback — capture first, then decide.
        local local_ip
        local_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
        echo "${local_ip:-(unavailable)}"
    fi
}

# ── Development ───────────────────────────────────────────────────────────────

# serve [port] — [python3] start a simple HTTP server in the current directory.
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

# tree-all [path] — [tree] tree with hidden files, colours, and pager.
tree-all() {
    if command -v tree &>/dev/null; then
        tree -aC -I '.git|node_modules|__pycache__|.venv' --dirsfirst "$@" | less -FRX
    else
        echo "tree-all: 'tree' is not installed" >&2; return 1
    fi
}

# weather [location] — [curl] quick weather report for a location.
weather() {
    if ! command -v curl &>/dev/null; then
        echo "weather: curl is not installed" >&2; return 1
    fi
    local location="${1:-}"
    curl -s --max-time 10 "https://wttr.in/${location}?format=v2"
}
