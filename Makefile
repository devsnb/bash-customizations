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

.PHONY: help install dotfiles update dry-run doctor doctor-quiet \
        uninstall uninstall-dry restore restore-only purge-tools \
        list-backups prune-backups lint docs docs-check \
        test test-unit test-docker check release release-dry

help: ## Show this help
	@printf '\n\033[1;36mbash-customizations\033[0m\n\n'
	@printf 'Usage: make \033[36m<target>\033[0m\n\n'
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@printf '\n'
	@printf 'Variables: \033[36mBACKUP\033[0m=<timestamp> for restore, \033[36mKEEP\033[0m=<n> for prune-backups\n\n'

# ── Install ───────────────────────────────────────────────────────────────────

install: ## Install all tools + deploy dotfiles
	@bash $(REPO_DIR)/setup.sh

dotfiles: ## Deploy dotfiles only — skip tool installation
	@bash $(REPO_DIR)/setup.sh --skip-tools

update: ## Upgrade all tools AND re-deploy dotfiles (setup.sh --force)
	@bash $(REPO_DIR)/setup.sh --force

dry-run: ## Preview what install would do without making any changes
	@bash $(REPO_DIR)/setup.sh --dry-run

# ── Diagnose ──────────────────────────────────────────────────────────────────

doctor: ## Diagnose the setup and show fix instructions
	@bash $(REPO_DIR)/doctor.sh

doctor-quiet: ## Diagnose, printing only failures and warnings (for scripts/CI)
	@bash $(REPO_DIR)/doctor.sh --quiet

# ── Remove / restore ──────────────────────────────────────────────────────────

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

# ── Develop ───────────────────────────────────────────────────────────────────

lint: ## Syntax-check and shellcheck every script
	@bash $(REPO_DIR)/tests/lint.sh

docs: ## Regenerate the README alias/function tables from bash/*.sh
	@bash $(REPO_DIR)/tools/gen-docs.sh

docs-check: ## Fail if those tables are stale (fix with: make docs)
	@bash $(REPO_DIR)/tools/gen-docs.sh --check

test-unit: ## Run the unit tests (no container required)
	@bash $(REPO_DIR)/tests/unit.sh

test-docker: ## Run the full install/uninstall round trip in a container
	@bash $(REPO_DIR)/tests/docker.sh

test: test-unit test-docker ## Run all tests

check: lint docs-check test ## Lint + docs + all tests (what CI runs)

# ── Release ───────────────────────────────────────────────────────────────────
# make release VERSION=1.1.0 — checks, stamps, commits and tags.  Never pushes;
# `git push --follow-tags` is what starts the CI release job.
VERSION ?=

release: ## Cut a release locally: stamp, changelog, commit, tag (VERSION=X.Y.Z)
	@bash $(REPO_DIR)/tools/release.sh $(VERSION)

release-dry: ## Preview that release, changing nothing (VERSION=X.Y.Z)
	@bash $(REPO_DIR)/tools/release.sh --dry-run $(VERSION)
