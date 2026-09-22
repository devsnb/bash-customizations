#!/usr/bin/env bash
# tools/release.sh — cut a release: stamp VERSION, fold the CHANGELOG's
# Unreleased section into a dated heading, commit, and annotate a tag.
#
# It deliberately does NOT push.  Everything it does is local and undoable
# (git tag -d, git reset --hard); the push is the one irreversible step and
# stays an explicit act:
#
#     git push --follow-tags origin main
#
# That push is what starts the CI release job, which runs the whole suite
# against the tag and only then publishes the GitHub Release — using the same
# CHANGELOG section this script wrote, read back with --notes.
#
# Usage:
#   bash tools/release.sh 1.1.0             # check, stamp, commit, tag
#   bash tools/release.sh --dry-run 1.1.0   # print the exact diff and commands
#   bash tools/release.sh --notes 1.1.0     # print that section's body, nothing else
#   bash tools/release.sh --no-docker 1.1.0 # skip the container round trip locally
#   make release VERSION=1.1.0              # the usual way
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="${REPO_DIR}/VERSION"
CHANGELOG="${REPO_DIR}/CHANGELOG.md"
REPO_URL="https://github.com/devsnb/bash-customizations"
BRANCH="main"

# shellcheck source=../lib/log.sh
source "${REPO_DIR}/lib/log.sh"

MODE=release
NEW_VERSION=''
RUN_DOCKER=true

# die MESSAGE [HINT…] — refuse, and say what to do instead.
die() {
    log_error "$1"
    local hint
    for hint in "${@:2}"; do echo "        ${hint}" >&2; done
    exit 1
}

usage() { sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# version_gt A B — true when A is strictly newer than B.
# Field-by-field integer compare avoids depending on version-sort extensions.
version_gt() {
    local -a a b
    local i
    IFS=. read -r -a a <<< "$1"
    IFS=. read -r -a b <<< "$2"
    for i in 0 1 2; do
        if (( ${a[i]:-0} > ${b[i]:-0} )); then return 0; fi
        if (( ${a[i]:-0} < ${b[i]:-0} )); then return 1; fi
    done
    return 1
}

# changelog_section VERSION — print the body of that CHANGELOG section.
# Exits 3 when the section is missing or empty.  "Unreleased" is a valid VERSION.
changelog_section() {
    awk -v ver="$1" '
        # index() rather than a regex: the dots in "1.1.0" would otherwise be
        # metacharacters.  Anchoring at column 1 and including the closing
        # bracket means "## [1.1.0]" cannot match "## [1.1.10]".
        !inside { if (index($0, "## [" ver "]") == 1) inside = 1; next }
        index($0, "## [") == 1 { exit }
        # Blank lines are held back and replayed only when real text follows, so
        # the body comes out without leading or trailing padding while its
        # interior spacing survives.
        NF == 0 { if (started) blank++; next }
        { for (; blank > 0; blank--) print ""; started = 1; print }
        END { if (!started) exit 3 }
    ' "$CHANGELOG"
}

# ══════════════════════════════════════════════════════════════════════════════
# Arguments
# ══════════════════════════════════════════════════════════════════════════════

for arg in "$@"; do
    case "$arg" in
        --dry-run)   MODE=dry   ;;
        --notes)     MODE=notes ;;
        --no-docker) RUN_DOCKER=false ;;
        -h|--help)   usage; exit 0 ;;
        -*)          die "Unknown argument: ${arg}  (use --help)" ;;
        *)
            if [[ -n "$NEW_VERSION" ]]; then
                die "Two versions given: ${NEW_VERSION} and ${arg}" \
                    "Pass exactly one, e.g.: bash tools/release.sh 1.1.0"
            fi
            NEW_VERSION="$arg"
            ;;
    esac
done

# Validated before any git or make work, so a typo costs nothing and the unit
# tests can exercise these against a dirty tree.
if [[ -z "$NEW_VERSION" ]]; then
    die "No version given." \
        "Usage: bash tools/release.sh [--dry-run] X.Y.Z" \
        "   or: make release VERSION=X.Y.Z"
fi

case "$NEW_VERSION" in
    v*) die "Give the version without the leading 'v': ${NEW_VERSION#v}, not ${NEW_VERSION}." \
            "The 'v' belongs to the git tag; VERSION holds the bare number." ;;
esac

if ! [[ "$NEW_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    die "Not a valid version: ${NEW_VERSION}" \
        "Expected MAJOR.MINOR.PATCH, no leading zeros, no suffix (e.g. 1.1.0)."
fi

TAG="v${NEW_VERSION}"
TODAY="$(date +%F)"

[[ -f "$CHANGELOG" ]] || die "No CHANGELOG.md at ${CHANGELOG}"

# --notes is a pure read: no git, no preconditions.  This is what CI shells out
# to when it builds the GitHub Release body.
if [[ "$MODE" == 'notes' ]]; then
    changelog_section "$NEW_VERSION" || \
        die "CHANGELOG.md has no section for ${NEW_VERSION}." \
            "Expected a heading:  ## [${NEW_VERSION}] - YYYY-MM-DD"
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# Preconditions — every one refuses with what to do instead
# ══════════════════════════════════════════════════════════════════════════════

has git || die "git is not installed."
git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 || \
    die "${REPO_DIR} is not a git repository."
[[ -f "$VERSION_FILE" ]] || \
    die "No VERSION file at ${VERSION_FILE}" \
        "Create it with the currently released version:  echo 1.0.0 > VERSION"

current_branch="$(git -C "$REPO_DIR" symbolic-ref --quiet --short HEAD || true)"
[[ "$current_branch" == "$BRANCH" ]] || \
    die "Releases are cut from ${BRANCH}, not ${current_branch:-a detached HEAD}." \
        "Switch first:  git switch ${BRANCH}"

# Untracked files count as dirty: an untracked file is usually something that
# should have been part of the release.
if [[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]]; then
    die "The working tree is not clean — commit or stash first." \
        "See what is outstanding:  git status --short"
fi

if git -C "$REPO_DIR" rev-parse --verify --quiet "refs/remotes/origin/${BRANCH}" >/dev/null; then
    git -C "$REPO_DIR" fetch --quiet --tags origin "$BRANCH" 2>/dev/null || \
        log_warn "Could not reach origin — comparing against the last known state."
    behind="$(git -C "$REPO_DIR" rev-list --count "HEAD..origin/${BRANCH}")"
    (( behind == 0 )) || \
        die "Local ${BRANCH} is ${behind} commit(s) behind origin/${BRANCH}." \
            "Catch up first:  git pull --ff-only"
else
    log_warn "No origin/${BRANCH} — releasing from a local-only branch."
fi

# A tag already on HEAD means a release was cut and never pushed.
already="$(git -C "$REPO_DIR" tag --points-at HEAD | tr '\n' ' ')"
[[ -z "$already" ]] || \
    die "HEAD is already tagged: ${already% }" \
        "That release was cut but never pushed.  Push it:" \
        "  git push --follow-tags origin ${BRANCH}"

if git -C "$REPO_DIR" rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    die "Tag ${TAG} already exists locally." \
        "Pick the next version, or drop it:  git tag -d ${TAG}"
fi
if git -C "$REPO_DIR" ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1; then
    die "Tag ${TAG} already exists on origin — that release is public." \
        "Versions are never reused; pick the next one."
fi

IFS= read -r CURRENT_VERSION < "$VERSION_FILE" || true
CURRENT_VERSION="${CURRENT_VERSION%$'\r'}"
version_gt "$NEW_VERSION" "$CURRENT_VERSION" || \
    die "${NEW_VERSION} is not newer than the current version ${CURRENT_VERSION}." \
        "Versions only ever go up."

grep -q '^## \[Unreleased\]' "$CHANGELOG" || \
    die "CHANGELOG.md has no '## [Unreleased]' heading." \
        "release.sh promotes that section; put it back before releasing."
grep -q '^\[Unreleased\]:' "$CHANGELOG" || \
    die "CHANGELOG.md has no '[Unreleased]:' link reference at the bottom." \
        "Add:  [Unreleased]: ${REPO_URL}/compare/v${CURRENT_VERSION}...HEAD"
if grep -q "^## \[${NEW_VERSION}\]" "$CHANGELOG"; then
    die "CHANGELOG.md already has a section for ${NEW_VERSION}." \
        "Either that release happened, or the heading was written by hand."
fi

notes="$(changelog_section Unreleased || true)"
[[ -n "$notes" ]] || \
    die "The Unreleased section of CHANGELOG.md is empty — nothing to release." \
        "Write what changed under ### Added / ### Changed / ### Fixed / ### Removed."

# ══════════════════════════════════════════════════════════════════════════════
# The suite — before anything is written, so a red run leaves the tree untouched
# ══════════════════════════════════════════════════════════════════════════════

log_section "Pre-release checks"
if $RUN_DOCKER; then
    check_target='check'
else
    check_target='lint docs-check test-unit'
    log_warn "Skipping the container round trip (--no-docker) — CI still runs it on the tag."
fi
# shellcheck disable=SC2086  # check_target is a deliberate multi-word target list
check_log="$(mktemp)"
trap 'rm -f "$check_log"' EXIT
if ! make -C "$REPO_DIR" $check_target 2>&1 | tee "$check_log"; then
    die "make ${check_target} failed — nothing has been changed." \
        "Fix the failures, then run the release again."
fi

# `make check` passes when Docker is unreachable, because tests/docker.sh skips
# by design.  Say so plainly rather than letting a release look fully tested.
if $RUN_DOCKER && grep -q '^SKIP:' "$check_log"; then
    log_warn "The container round trip SKIPPED (no Docker) — CI will run it on the tag."
fi
rm -f "$check_log"
trap - EXIT

# ══════════════════════════════════════════════════════════════════════════════
# Build the new files (both modes build them; only the real mode installs them)
# ══════════════════════════════════════════════════════════════════════════════

# Temp files live inside the repo so the final mv is a rename on the same
# filesystem, matching what tools/gen-docs.sh does for README.md.
tmp_version="$(mktemp "${REPO_DIR}/.VERSION.XXXXXX")"
tmp_changelog="$(mktemp "${REPO_DIR}/.CHANGELOG.XXXXXX")"
trap 'rm -f "$tmp_version" "$tmp_changelog"' EXIT

printf '%s\n' "$NEW_VERSION" > "$tmp_version"

# The release before the first script-cut one may have no tag; fall back to a
# plain release link rather than emitting a broken compare link.
if git -C "$REPO_DIR" rev-parse -q --verify "refs/tags/v${CURRENT_VERSION}" >/dev/null; then
    new_link="${REPO_URL}/compare/v${CURRENT_VERSION}...${TAG}"
else
    new_link="${REPO_URL}/releases/tag/${TAG}"
fi

awk -v ver="$NEW_VERSION" -v date="$TODAY" -v url="$REPO_URL" -v newlink="$new_link" '
    # The Unreleased heading becomes an empty Unreleased plus the new dated
    # heading.  Whatever was under Unreleased stays exactly where it is and is
    # now under the release heading — no buffering, no reordering.
    !promoted && index($0, "## [Unreleased]") == 1 {
        print "## [Unreleased]"
        print ""
        print "## [" ver "] - " date
        promoted = 1
        next
    }
    # Unreleased now compares against the new tag, and the new version gets its
    # own link line directly beneath it.
    !linked && index($0, "[Unreleased]:") == 1 {
        print "[Unreleased]: " url "/compare/v" ver "...HEAD"
        print "[" ver "]: " newlink
        linked = 1
        next
    }
    { print }
    END { if (!promoted || !linked) exit 3 }
' "$CHANGELOG" > "$tmp_changelog" || \
    die "Could not rewrite CHANGELOG.md — its structure is not what release.sh expects." \
        "Nothing has been changed."

# ══════════════════════════════════════════════════════════════════════════════
# Dry run
# ══════════════════════════════════════════════════════════════════════════════

if [[ "$MODE" == 'dry' ]]; then
    log_section "Dry run — nothing was written"
    echo "  VERSION    ${CURRENT_VERSION}  ${GLYPH_ARROW}  ${NEW_VERSION}"
    echo "  commit     release ${TAG}   (on $(git -C "$REPO_DIR" rev-parse --short HEAD))"
    echo "  tag        ${TAG}   (annotated; message is the notes below)"
    echo
    echo "  CHANGELOG.md would change like this:"
    diff -u "$CHANGELOG" "$tmp_changelog" | sed 's/^/    /' || true
    echo
    echo "  The GitHub Release would be published with these notes:"
    printf '%s\n' "$notes" | sed 's/^/    /'
    echo
    echo "  Then, and only then:  git push --follow-tags origin ${BRANCH}"
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# Commit and tag
# ══════════════════════════════════════════════════════════════════════════════

# mktemp creates 0600 and `mv` carries that mode across with the inode, so
# without this the two files git tracks as 100644 end up owner-only on disk
# after every release.  (tools/gen-docs.sh escapes this by using `cp` onto the
# existing README, which keeps the destination's mode.)
chmod 644 "$tmp_version" "$tmp_changelog"

mv "$tmp_version"   "$VERSION_FILE"
mv "$tmp_changelog" "$CHANGELOG"
trap - EXIT

git -C "$REPO_DIR" add -- VERSION CHANGELOG.md
if ! git -C "$REPO_DIR" commit -q -m "release ${TAG}"; then
    die "git commit failed — VERSION and CHANGELOG.md are edited but not committed." \
        "Undo with:  git restore --staged --worktree VERSION CHANGELOG.md"
fi

# --cleanup=whitespace matters: git's default strips every line starting with
# '#', which would eat the "### Added" headings out of the tag message.
if ! { printf '%s\n\n' "$TAG"; printf '%s\n' "$notes"; } \
     | git -C "$REPO_DIR" tag -a "$TAG" --cleanup=whitespace -F -; then
    die "git tag failed — the release commit exists but is not tagged." \
        "Tag it by hand, or undo the commit:  git reset --hard HEAD~1"
fi

log_ok "Committed and tagged ${TAG}"
echo
echo "  Nothing has been pushed.  Review it:"
echo "    git show ${TAG}"
echo
echo "  Then publish — the push is what starts the CI release job:"
echo "    git push --follow-tags origin ${BRANCH}"
