#!/usr/bin/env bash
# lib/log.sh
#
# Shared output helpers for setup.sh, doctor.sh and uninstall.sh.
#
# This file is SOURCED by those scripts, never executed.  It deliberately
# contains no logic beyond defining the palette, the glyph set, and the log_*
# family, so that sourcing it can never have a side effect on the caller.
#
# Two things it decides on the caller's behalf:
#
#   1. Whether to emit colour at all.  Every call site refers to the palette
#      through variables (${RED}, ${GREEN}, …), so switching them to empty
#      strings here disables colour everywhere without touching a single call.
#   2. Whether the terminal can render box-drawing and check-mark characters.
#      A first-run user has not installed a Nerd Font yet and may be in the C
#      locale, where those bytes come out as mojibake.
#
# shellcheck disable=SC2034
#   The palette and glyph variables are consumed by the scripts that source
#   this file, which shellcheck analyses as separate units and so reports as
#   "appears unused".  They are all used; see setup.sh / doctor.sh / uninstall.sh.
# ─────────────────────────────────────────────────────────────────────────────

# ── Colour ────────────────────────────────────────────────────────────────────
# Suppressed when stdout is not a terminal (redirected to a file, piped into
# `cat`, captured by CI) or when NO_COLOR is set to anything at all, per the
# https://no-color.org convention.  doctor.sh advertises --quiet for scripts;
# without this it wrote raw escape sequences into their logs.
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
    RED=''; YELLOW=''; GREEN=''; BLUE=''; CYAN=''; BOLD=''; RESET=''
else
    RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
fi

# ── Glyphs ────────────────────────────────────────────────────────────────────
# Only the effective ctype locale decides this: LC_ALL wins, then LC_CTYPE,
# then LANG.  exports.sh explains why we never set LC_ALL ourselves, but a user
# or a container may well have.
_log_locale="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
if [[ "${_log_locale,,}" == *utf*8* ]]; then
    GLYPH_OK='✔'; GLYPH_FAIL='✘'; GLYPH_WARN='!'; GLYPH_INFO='i'; GLYPH_ARROW='→'
    RULE_HEAVY='══'; RULE_LIGHT='──'
    BOX_H='═'; BOX_V='║'; BOX_TL='╔'; BOX_TR='╗'; BOX_BL='╚'; BOX_BR='╝'
else
    GLYPH_OK='+'; GLYPH_FAIL='x'; GLYPH_WARN='!'; GLYPH_INFO='i'; GLYPH_ARROW='->'
    RULE_HEAVY='=='; RULE_LIGHT='--'
    BOX_H='='; BOX_V='|'; BOX_TL='+'; BOX_TR='+'; BOX_BL='+'; BOX_BR='+'
fi
unset _log_locale

# Which rule log_section draws.  Set to "$RULE_LIGHT" after sourcing to get a
# lighter heading — doctor.sh does that, because its sections group individual
# checks rather than whole phases of a run.
SECTION_RULE="$RULE_HEAVY"

# ── Log helpers ───────────────────────────────────────────────────────────────
# The trailing spaces line the message column up across all five prefixes.
log_info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_dry()     { echo -e "${YELLOW}[DRY]${RESET}   $*"; }
log_skip()    { echo -e "        (skipped) $*"; }
log_section() { echo -e "\n${BOLD}${CYAN}${SECTION_RULE} $* ${SECTION_RULE}${RESET}"; }

# log_banner SCRIPT — the boxed title each script opens with.
log_banner() {
    local text="bash-customizations  $1"
    local inner=50 rule='' pad_left pad_right i

    for (( i = 0; i < inner; i++ )); do rule+="$BOX_H"; done
    pad_left=$(( (inner - ${#text}) / 2 ))
    pad_right=$(( inner - ${#text} - pad_left ))

    echo -e "${BOLD}${CYAN}"
    echo "${BOX_TL}${rule}${BOX_TR}"
    printf '%s%*s%s%*s%s\n' "$BOX_V" "$pad_left" '' "$text" "$pad_right" '' "$BOX_V"
    echo "${BOX_BL}${rule}${BOX_BR}"
    echo -e "${RESET}"
}

# has CMD — true if the command exists on PATH.
has() { command -v "$1" &>/dev/null; }
