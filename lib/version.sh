#!/usr/bin/env bash
# lib/version.sh
#
# The repo's own version, read from the VERSION file at the repo root.
#
# SOURCED by setup.sh, doctor.sh and uninstall.sh, never executed.  VERSION
# holds a single line, MAJOR.MINOR.PATCH, with no leading "v" — the v belongs to
# the git tag, not to the number.  tools/release.sh writes it, setup.sh stamps
# it into the install manifest, doctor.sh compares the two, and the CI release
# job checks it against the tag it is about to publish.
#
# This lives apart from lib/log.sh on purpose: that file promises in its own
# header to have no side effects at source time, and reading a file is exactly
# such a side effect.
#
# A missing or unreadable VERSION yields "unknown" rather than an error — a
# script run out of a downloaded tarball must still work — and every consumer
# treats "unknown" as "do not compare".
#
# shellcheck disable=SC2034
#   BC_VERSION is consumed by the scripts that source this file, which are
#   analysed as separate units and so report it as unused.
# ─────────────────────────────────────────────────────────────────────────────

BC_VERSION=''
_bc_version_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/VERSION"
# `read` returns non-zero on a file with no trailing newline but still assigns,
# so the value is taken afterwards rather than gated on its exit status.
if [[ -r "$_bc_version_file" ]]; then
    IFS= read -r BC_VERSION < "$_bc_version_file" || true
fi
BC_VERSION="${BC_VERSION%$'\r'}"        # tolerate a CRLF checkout
BC_VERSION="${BC_VERSION:-unknown}"
unset _bc_version_file

# print_version SCRIPT — what every root script prints for --version.
#
# Line 1 is machine-readable (`bash setup.sh --version | awk '{print $2}'`).
# Line 2 answers the question people actually ask, which is *which* checkout
# they just ran.
print_version() {
    echo "bash-customizations ${BC_VERSION}"
    echo "${1} from ${REPO_DIR}"
}
