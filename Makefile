SHELL  := bash
.DEFAULT_GOAL := help

.PHONY: help install dotfiles update dry-run doctor uninstall restore purge list-backups

help:
	@printf '\n\033[1;36mbash-customizations\033[0m\n\n'
	@printf 'Usage: make \033[36m<target>\033[0m\n\n'
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@printf '\n'

install: ## Install all tools + deploy dotfiles
	@bash setup.sh

dotfiles: ## Deploy dotfiles only — skip tool installation
	@bash setup.sh --skip-tools

update: ## Reinstall / upgrade all tools to latest versions
	@bash setup.sh --force

dry-run: ## Preview what install would do without making any changes
	@bash setup.sh --dry-run

doctor: ## Diagnose the setup and show fix instructions
	@bash doctor.sh

uninstall: ## Remove managed symlinks and blocks from ~/.bashrc
	@bash uninstall.sh

restore: ## Uninstall and restore the most recent backup
	@bash uninstall.sh --restore

purge: ## Uninstall and remove all tool binaries (starship, fzf, zoxide, ble.sh)
	@bash uninstall.sh --purge-tools

list-backups: ## List available backup timestamps
	@bash uninstall.sh --list-backups
