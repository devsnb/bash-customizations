SHELL  := bash
.DEFAULT_GOAL := help

# Recipes must work from anywhere, not only from the repo root.
REPO_DIR := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))

# make restore BACKUP=20250604_142301  → restore that specific backup
# make restore                         → restore the backup recorded at install
BACKUP ?=
RESTORE_ARG := $(if $(BACKUP),--restore=$(BACKUP),--restore)

# make prune-backups KEEP=3
KEEP ?=
PRUNE_ARG := $(if $(KEEP),--prune-backups=$(KEEP),--prune-backups)

.PHONY: help install dotfiles update update-tools version dry-run doctor doctor-quiet \
        uninstall uninstall-dry restore restore-only purge-tools \
        list-backups prune-backups lint docs docs-check tools-lock tools-update tools-outdated \
        test test-unit test-docker check release release-dry

##@ General

# Groups come from the "##@ Name" lines below, so the order you read here is
# the order the source is written in — the two cannot drift apart.
help: ## Show this help
	@printf '\n\033[1;36mbash-customizations\033[0m  \033[2m%s\033[0m\n' "$$(cat $(REPO_DIR)/VERSION 2>/dev/null)"
	@printf '\nUsage: make \033[36m<target>\033[0m\n'
	@awk 'BEGIN {FS = ":.*## "} \
	     /^##@ / { printf "\n  \033[1m%s\033[0m\n", substr($$0, 5); next } \
	     /^[a-zA-Z_-]+:.*## / { printf "    \033[36m%-14s\033[0m %s\n", $$1, $$2 }' \
	     $(MAKEFILE_LIST)
	@printf '\n  \033[1mVariables\033[0m\n'
	@printf '    \033[36m%-16s\033[0m %s\n' \
		'BACKUP=<ts>'  'which backup restore / restore-only uses' \
		'KEEP=<n>'     'how many backups prune-backups keeps (default 5)' \
		'VERSION=<x.y.z>' 'the version release / release-dry cuts'
	@printf '\n'

# ─────────────────────────────────────────────────────────────────────────────
##@ Install & update

install: ## Install all tools + deploy dotfiles
	@bash $(REPO_DIR)/setup.sh

dotfiles: ## Deploy dotfiles only — skip tool installation
	@bash $(REPO_DIR)/setup.sh --skip-tools

# "update" means what a user means by it: get the newest release.  The
# tools-only behaviour this used to have lives on as update-tools.
update: ## Fetch the newest release, then re-install tools and dotfiles
	@git -C $(REPO_DIR) pull --ff-only
	@bash $(REPO_DIR)/setup.sh --force

update-tools: ## Reinstall the tool versions pinned by this checkout
	@bash $(REPO_DIR)/setup.sh --force

dry-run: ## Preview what install would do without making any changes
	@bash $(REPO_DIR)/setup.sh --dry-run

# ─────────────────────────────────────────────────────────────────────────────
##@ Inspect

version: ## Show this checkout's version and the one currently installed
	@bash $(REPO_DIR)/setup.sh --version
	@installed=$$(grep -m1 '^VERSION=' "$$HOME/.local/share/bash-customizations/manifest" 2>/dev/null); \
	 if [ -n "$$installed" ]; then echo "installed v$${installed#VERSION=}"; \
	 else echo "installed version not recorded — run: make update"; fi

doctor: ## Diagnose the setup and show fix instructions
	@bash $(REPO_DIR)/doctor.sh

doctor-quiet: ## Diagnose, printing only failures and warnings (for scripts/CI)
	@bash $(REPO_DIR)/doctor.sh --quiet

# ─────────────────────────────────────────────────────────────────────────────
##@ Remove & restore

uninstall: ## Remove managed symlinks and blocks from ~/.bashrc
	@bash $(REPO_DIR)/uninstall.sh

uninstall-dry: ## Preview exactly what uninstall would remove
	@bash $(REPO_DIR)/uninstall.sh --dry-run

restore: ## Uninstall and restore a backup (BACKUP=<timestamp> to choose one)
	@bash $(REPO_DIR)/uninstall.sh $(RESTORE_ARG)

restore-only: ## Restore a backup WITHOUT uninstalling (BACKUP=<timestamp>)
	@bash $(REPO_DIR)/uninstall.sh $(subst --restore,--restore-only,$(RESTORE_ARG))

purge-tools: ## Uninstall and remove tool binaries (starship, fzf, zoxide, ble.sh)
	@bash $(REPO_DIR)/uninstall.sh --purge-tools

list-backups: ## List available backup timestamps
	@bash $(REPO_DIR)/uninstall.sh --list-backups

prune-backups: ## Delete all but the newest backups (KEEP=<n>, default 5)
	@bash $(REPO_DIR)/uninstall.sh $(PRUNE_ARG)

# ─────────────────────────────────────────────────────────────────────────────
##@ Develop

lint: ## Syntax-check and shellcheck every script
	@bash $(REPO_DIR)/tests/lint.sh

docs: ## Regenerate the README alias/function tables from bash/*.sh
	@bash $(REPO_DIR)/tools/gen-docs.sh

docs-check: ## Fail if those tables are stale (fix with: make docs)
	@bash $(REPO_DIR)/tools/gen-docs.sh --check

tools-lock: ## Re-download and verify every version currently in tools.lock
	@bash $(REPO_DIR)/tools/lock-tools.sh

tools-update: ## Pin every managed tool to its newest published release
	@bash $(REPO_DIR)/tools/lock-tools.sh --latest

tools-outdated: ## Report whether newer managed-tool releases are available
	@bash $(REPO_DIR)/tools/lock-tools.sh --check

test-unit: ## Run the unit tests (no container required)
	@bash $(REPO_DIR)/tests/unit.sh

test-docker: ## Run the full install/uninstall round trip in a container
	@bash $(REPO_DIR)/tests/docker.sh

test: test-unit test-docker ## Run all tests

check: lint docs-check test ## Lint + docs + all tests (what CI runs)

# ─────────────────────────────────────────────────────────────────────────────
##@ Release
# make release VERSION=1.1.0 — checks, stamps, commits and tags.  Never pushes;
# `git push --follow-tags` is what starts the CI release job.
VERSION ?=

release: ## Cut a release locally: stamp, changelog, commit, tag (VERSION=X.Y.Z)
	@bash $(REPO_DIR)/tools/release.sh $(VERSION)

release-dry: ## Preview that release, changing nothing (VERSION=X.Y.Z)
	@bash $(REPO_DIR)/tools/release.sh --dry-run $(VERSION)
