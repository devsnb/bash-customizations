#!/usr/bin/env bash
# ~/.bash/aliases.sh
#
# Shell aliases, organised by category.
# Add your own at the bottom of each section or create a new section.
# ─────────────────────────────────────────────────────────────────────────────

# ── Safety rails ──────────────────────────────────────────────────────────────
# Prompt before overwriting/deleting files.
alias cp='cp -iv'
alias mv='mv -iv'
alias rm='rm -iv'
alias mkdir='mkdir -pv'

# ── Directory listing ─────────────────────────────────────────────────────────
# Prefer eza (modern ls replacement) if available; fall back to ls.
if command -v eza &>/dev/null; then
    alias ls='eza --group-directories-first --icons=auto --color=auto'
    alias ll='eza -lah --group-directories-first --icons=auto --git'
    alias la='eza -a   --group-directories-first --icons=auto'
    alias l='eza --icons=auto --color=auto'        # short form, consistent with fallback
    alias lt='eza --tree --level=2 --icons=auto'
    alias llt='eza --tree --level=3 -lah --icons=auto --git'
else
    # Colorize ls output.  GNU ls uses --color; BSD ls uses -G.
    if ls --color=auto --group-directories-first &>/dev/null; then
        alias ls='ls --color=auto --group-directories-first'
    elif ls --color=auto &>/dev/null; then
        alias ls='ls --color=auto'
    else
        alias ls='ls -G'    # BSD/macOS
    fi
    alias ll='ls -lahF'
    alias la='ls -AF'
    alias l='ls -CF'
fi

# ── Navigation ────────────────────────────────────────────────────────────────
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ~='cd ~'
alias -- -='cd -'    # cd to previous directory

# ── File viewing ──────────────────────────────────────────────────────────────
# Prefer bat (syntax-highlighted cat) when available.
if command -v bat &>/dev/null; then
    alias cat='bat --paging=never'
    alias less='bat --paging=always'
elif command -v batcat &>/dev/null; then   # Debian/Ubuntu package name
    alias cat='batcat --paging=never'
    alias less='batcat --paging=always'
fi

# ── Grep ──────────────────────────────────────────────────────────────────────
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# ── Disk usage ────────────────────────────────────────────────────────────────
alias df='df -h'
alias du='du -h'
alias dud='du -d1 -h'    # disk usage of immediate subdirectories
alias duf='du -sh *'     # disk usage of files in current dir

# ── Processes ─────────────────────────────────────────────────────────────────
alias psa='ps auxf'
alias psg='ps aux | grep -v grep | grep -i'   # e.g. psg nginx

# ── Network ───────────────────────────────────────────────────────────────────
alias ping='ping -c 5'
alias ports='ss -tulpn'

# ── Editor ────────────────────────────────────────────────────────────────────
alias v='${EDITOR:-nvim}'
alias vi='${EDITOR:-nvim}'

# ── Git ───────────────────────────────────────────────────────────────────────
alias g='git'
alias gs='git status -sb'
alias ga='git add'
alias gaa='git add --all'
alias gc='git commit'
alias gcm='git commit -m'
alias gco='git checkout'
alias gd='git diff'
alias gds='git diff --staged'
alias gl='git log --oneline --graph --decorate --all'
alias gp='git push'
alias gpl='git pull'
alias gb='git branch'
alias gba='git branch -a'
alias gst='git stash'
alias gstp='git stash pop'

# ── Docker ────────────────────────────────────────────────────────────────────
if command -v docker &>/dev/null; then
    alias dk='docker'
    alias dkps='docker ps'
    alias dkpsa='docker ps -a'
    alias dki='docker images'
    alias dkrm='docker rm'
    alias dkrmi='docker rmi'
    alias dkx='docker exec -it'
    alias dkl='docker logs -f'
    alias dkc='docker compose'
    alias dkcu='docker compose up -d'
    alias dkcd='docker compose down'
fi

# ── System ────────────────────────────────────────────────────────────────────
alias h='history'
alias j='jobs -l'
alias path='echo -e "${PATH//:/\\n}"'   # print PATH entries, one per line
alias now='date +"%Y-%m-%d %T"'
alias week='date +%V'                   # ISO week number

# Full terminal reset — clears screen, scrollback buffer, and all terminal state.
# (ESC c = RIS "Reset to Initial State". Use `clear` to clear only the visible
# screen while preserving scrollback.)
alias cls='printf "\033c"'

# ── Reload / edit config ──────────────────────────────────────────────────────
alias bashrc='${EDITOR:-nvim} ~/.bashrc'
alias aliases='${EDITOR:-nvim} ~/.bash/aliases.sh'
