# tests/integration/Dockerfile
#
# Three environments, because the interesting failures are environmental:
#
#   sudo-user    a normal user with passwordless sudo — the ordinary case
#   user-nosudo  a normal user with NO sudo installed — must degrade, not abort
#   root-nosudo  root with NO sudo installed — the container case; `sudo apt-get`
#                would fail here, and used to take the whole install down with it
# ─────────────────────────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS base

ENV DEBIAN_FRONTEND=noninteractive

# Deliberately minimal: bash, a downloader, git, and the tar/xz pair ble.sh
# needs.  Anything setup.sh requires beyond this is a bug in its prerequisite
# check, and this image is what proves it.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git less locales procps xz-utils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /repo

# ── A normal user with sudo ───────────────────────────────────────────────────
FROM base AS sudo-user
RUN apt-get update \
 && apt-get install -y --no-install-recommends sudo \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash tester \
 && echo 'tester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tester \
 && chmod 0440 /etc/sudoers.d/tester
USER tester
ENV HOME=/home/tester

# ── A normal user without sudo ────────────────────────────────────────────────
FROM base AS user-nosudo
RUN useradd -m -s /bin/bash tester
USER tester
ENV HOME=/home/tester

# ── Root without sudo ─────────────────────────────────────────────────────────
FROM base AS root-nosudo
ENV HOME=/root
