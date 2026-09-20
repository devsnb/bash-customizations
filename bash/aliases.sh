#!/usr/bin/env bash
# ~/.bash/aliases.sh
#
# Shell aliases, organised by category.
# Add your own at the bottom of each section or create a new section.
#
# Every alias carries a description after a ` #: ` sigil.  That is not decoration
# — `cheatsheet` and the README tables are both generated from these lines, so an
# alias without one is invisible to users and fails `make test-unit`.
#
#   alias name='body'    #: what it does
#   alias name='body'    #: [tool] what it does      ← only exists if `tool` is
#                                                      installed
#
# A plain trailing `# note` is ignored on purpose, so you can still leave a
# remark for whoever reads the source.  Where the same name is defined twice
# (see `ls` below), annotate one definition only.
# ─────────────────────────────────────────────────────────────────────────────

# ── Safety rails ──────────────────────────────────────────────────────────────
# Prompt before overwriting/deleting files.
alias cp='cp -iv'        #: copy, asking first and saying what it did
alias mv='mv -iv'        #: move, asking first and saying what it did
alias rm='rm -iv'        #: delete, asking about each file
alias mkdir='mkdir -pv'  #: make a directory, parents included

# ── Directory listing ─────────────────────────────────────────────────────────
# Prefer eza (modern ls replacement) if available; fall back to ls.
# Only the eza branch is annotated: the fallback defines the same four names, and
# each name belongs in the cheatsheet once.
#
# shellcheck disable=SC2262,SC2263  # this file is SOURCED into an interactive
# shell, not run as a script, so the aliases defined here do take effect for the
# user's later commands; shellcheck's same-parsing-unit rule does not apply.
if command -v eza &>/dev/null; then
    alias ls='eza --group-directories-first --icons=auto --color=auto'   #: list files, directories first
    alias ll='eza -lah --group-directories-first --icons=auto --git'     #: long listing with sizes, dates and git state
    alias la='eza -a   --group-directories-first --icons=auto'           #: list everything, dotfiles included
    alias l='eza --icons=auto --color=auto'                              #: compact listing
    alias lt='eza --tree --level=2 --icons=auto'                         #: [eza] tree view, two levels deep
    alias llt='eza --tree --level=3 -lah --icons=auto --git'             #: [eza] tree view, three levels deep, long form
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
alias ..='cd ..'          #: go up one directory
alias ...='cd ../..'      #: go up two directories
alias ....='cd ../../..'  #: go up three directories
alias ~='cd ~'            #: go to your home directory
alias -- -='cd -'         #: go back to the previous directory

# ── Grep ──────────────────────────────────────────────────────────────────────
alias grep='grep --color=auto'    #: grep with matches highlighted
alias fgrep='fgrep --color=auto'  #: grep for a literal string, highlighted
alias egrep='egrep --color=auto'  #: grep with extended regexes, highlighted

# ── Disk usage ────────────────────────────────────────────────────────────────
alias df='df -h'             #: free space per filesystem, in readable units
alias du='du -h'             #: disk usage, in readable units
alias du-dirs='du -d1 -h'    #: size of each subdirectory below here
alias du-files='du -sh *'    #: size of each entry in this directory

# ── Processes ─────────────────────────────────────────────────────────────────
# `f` (ASCII-art forest) is GNU procps only — BSD ps on macOS rejects it and
# prints usage instead of a process list.  Only the GNU branch is annotated;
# both define the same name.
if [[ "$OSTYPE" == darwin* ]]; then
    alias psa='ps aux'
else
    alias psa='ps auxf'                        #: every process, as a tree
fi
alias psg='ps aux | grep -v grep | grep -i'    #: search the process list, e.g. psg nginx

# ── Network ───────────────────────────────────────────────────────────────────
alias ping='ping -c 5'    #: ping, stopping after five packets
# `ports` is a function in functions.sh — ss does not exist on macOS, so it
# needs the same ss/lsof fallback that `port` already has.

# ── Editor ────────────────────────────────────────────────────────────────────
# No `vi` alias here on purpose: it shadows /usr/bin/vi, so `vi file` would open
# nano.  `v` is ours to define — nothing on a stock system is called that.
alias v='${EDITOR:-nano}'   #: open a file in $EDITOR

# ── Git ───────────────────────────────────────────────────────────────────────
alias g='git'                                            #: git
alias gs='git status -sb'                                #: short status with branch and ahead/behind
alias ga='git add'                                       #: stage a file
alias gaa='git add --all'                                #: stage every change
alias gc='git commit'                                    #: commit staged changes
alias gcm='git commit -m'                                #: commit with a message
alias gco='git checkout'                                 #: switch branch or restore a file
alias gd='git diff'                                      #: what has changed but is not staged
alias gds='git diff --staged'                            #: what is staged for the next commit
alias gl='git log --oneline --graph --decorate --all'    #: one-line commit graph of every branch
alias gp='git push'                                      #: push to the remote
alias gpl='git pull'                                     #: pull from the remote
alias gb='git branch'                                    #: list local branches
alias gba='git branch -a'                                #: list local and remote branches
alias gst='git stash'                                    #: stash your uncommitted changes
alias gstp='git stash pop'                               #: reapply the most recent stash

# ── Docker ────────────────────────────────────────────────────────────────────
if command -v docker &>/dev/null; then
    alias dk='docker'                    #: [docker] docker
    alias dkps='docker ps'               #: [docker] running containers
    alias dkpsa='docker ps -a'           #: [docker] every container, stopped ones included
    alias dki='docker images'            #: [docker] images on this machine
    alias dkrm='docker rm'               #: [docker] remove a container
    alias dkrmi='docker rmi'             #: [docker] remove an image
    alias dkx='docker exec -it'          #: [docker] run a command in a running container
    alias dkl='docker logs -f'           #: [docker] follow a container's logs
    alias dkc='docker compose'           #: [docker] docker compose
    alias dkcu='docker compose up -d'    #: [docker] start the compose stack detached
    alias dkcd='docker compose down'     #: [docker] stop and remove the compose stack
fi

# ── System ────────────────────────────────────────────────────────────────────
alias h='history'                        #: your command history
alias j='jobs -l'                        #: background jobs, with their PIDs
alias path='echo -e "${PATH//:/\\n}"'    #: print each PATH entry on its own line
alias now='date +"%Y-%m-%d %T"'          #: the current date and time
alias week='date +%V'                    #: the current ISO week number

# Full terminal reset — clears screen, scrollback buffer, and all terminal state.
# (ESC c = RIS "Reset to Initial State". Use `clear` to clear only the visible
# screen while preserving scrollback.)
alias cls='printf "\033c"'   #: clear the screen and the scrollback buffer

# ── Reload / edit config ──────────────────────────────────────────────────────
alias bashrc='${EDITOR:-nano} ~/.bashrc'                      #: edit ~/.bashrc in $EDITOR
alias edit-aliases='${EDITOR:-nano} ~/.bash/aliases.sh'       #: edit this file in $EDITOR
