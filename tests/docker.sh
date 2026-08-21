#!/usr/bin/env bash
# tests/docker.sh — run the install round trip in clean containers.
#
# Usage:
#   bash tests/docker.sh              # every environment
#   bash tests/docker.sh sudo-user    # just one
#
# Skips (exit 0) with an explanation when Docker is unavailable, so `make test`
# stays useful on a machine without a running daemon.  CI always has one, so
# there the round trip really does run.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="${REPO_DIR}/tests/integration/Dockerfile"
IMAGE_PREFIX="bash-customizations-test"

# Each target is a build stage in tests/integration/Dockerfile.
ALL_TARGETS=(sudo-user user-nosudo root-nosudo)

if [[ $# -gt 0 ]]; then
    TARGETS=("$@")
else
    TARGETS=("${ALL_TARGETS[@]}")
fi

if ! command -v docker &>/dev/null; then
    echo "SKIP: docker is not installed — cannot run the container round trip."
    echo "      The unit tests (make test-unit) do not need it."
    exit 0
fi

if ! docker info &>/dev/null; then
    echo "SKIP: the docker daemon is not reachable (is Docker Desktop running?)."
    echo "      Start it and re-run, or rely on CI for this suite."
    exit 0
fi

failed=()

for target in "${TARGETS[@]}"; do
    image="${IMAGE_PREFIX}:${target}"

    printf '\n\033[1m══ %s ══\033[0m\n' "$target"

    if ! docker build --quiet --target "$target" -t "$image" -f "$DOCKERFILE" "$REPO_DIR" >/dev/null; then
        echo "  build FAILED"
        failed+=("$target (build)")
        continue
    fi

    # The repo is mounted read-only: setup.sh must never need to write into its
    # own checkout, and mounting it that way is how we find out if it does.
    if docker run --rm \
        -v "${REPO_DIR}:/repo:ro" \
        -e ALLOW_HOME_MUTATION=yes \
        "$image" \
        bash /repo/tests/integration/roundtrip.sh
    then
        printf '\033[0;32m  %s passed\033[0m\n' "$target"
    else
        printf '\033[0;31m  %s FAILED\033[0m\n' "$target"
        failed+=("$target")
    fi
done

echo
if [[ ${#failed[@]} -eq 0 ]]; then
    printf '\033[0;32m\033[1mall container suites passed\033[0m\n'
    exit 0
fi
printf '\033[0;31m\033[1mfailed: %s\033[0m\n' "${failed[*]}"
exit 1
