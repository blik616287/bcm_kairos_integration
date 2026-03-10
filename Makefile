# BCM + Kairos Edge Deployment
# ============================
# End-to-end build, test, and validation for BCM head node
# and Kairos edge compute nodes via PXE boot.
#
# Quick start:
#   cp env.json.example env.json   # Edit with your credentials
#   make setup                     # Check prerequisites
#   make download-iso              # Download BCM ISO
#   make all                       # Build everything
#
# See: make help

SHELL := /bin/bash
.DEFAULT_GOAL := help

# ---- Configuration ----

ENV_FILE := env.json
jq = $(shell jq -r '$(1) // empty' $(ENV_FILE) 2>/dev/null)

# Required (no defaults)
BCM_PASSWORD      := $(call jq,.bcm_password)
PALETTE_TOKEN     := $(call jq,.palette_token)
PALETTE_PROJECT   := $(call jq,.palette_project_uid)
JFROG_TOKEN       := $(call jq,.jfrog_token)

# Optional (with defaults)
BCM_HOSTNAME      := $(or $(call jq,.bcm_hostname),bcm11-headnode)
BCM_TIMEZONE      := $(or $(call jq,.bcm_timezone),America/Los_Angeles)
PALETTE_ENDPOINT  := $(or $(call jq,.palette_endpoint),api.spectrocloud.com)
JFROG_INSTANCE    := $(or $(call jq,.jfrog_instance),insightsoftmax.jfrog.io)
JFROG_REPO        := $(or $(call jq,.jfrog_repo),iso-releases)
ISO_FILENAME      := $(or $(call jq,.iso_filename),bcm-11.0-ubuntu2404.iso)

# Derived paths
ISO_PATH          := dist/$(ISO_FILENAME)

# Export common env vars for scripts
export BCM_PASSWORD BCM_HOSTNAME BCM_TIMEZONE
export PALETTE_ENDPOINT PALETTE_TOKEN PALETTE_PROJECT_UID=$(PALETTE_PROJECT)
export ISO_PATH

# SSH options (reused across targets)
SSH_OPTS := -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR

# ---- Validation helpers ----

_require-env:
	@[ -f $(ENV_FILE) ] || { echo "ERROR: $(ENV_FILE) not found. Run: cp env.json.example env.json"; exit 1; }

_require-bcm-password: _require-env
	@[ -n "$(BCM_PASSWORD)" ] || { echo "ERROR: bcm_password not set in $(ENV_FILE)"; exit 1; }

_require-palette: _require-env
	@[ -n "$(PALETTE_TOKEN)" ] || { echo "ERROR: palette_token not set in $(ENV_FILE)"; exit 1; }
	@[ -n "$(PALETTE_PROJECT)" ] || { echo "ERROR: palette_project_uid not set in $(ENV_FILE)"; exit 1; }

_require-jfrog: _require-env
	@[ -n "$(JFROG_TOKEN)" ] || { echo "ERROR: jfrog_token not set in $(ENV_FILE)"; exit 1; }

_require-iso:
	@[ -f "$(ISO_PATH)" ] || { echo "ERROR: ISO not found at $(ISO_PATH). Run: make download-iso"; exit 1; }

_require-bcm-running:
	@sshpass -p "$(BCM_PASSWORD)" ssh $(SSH_OPTS) -o ConnectTimeout=5 -p 10022 root@localhost "echo ok" >/dev/null 2>&1 \
		|| { echo "ERROR: BCM head node not reachable at localhost:10022. Run: make bcm-start"; exit 1; }

# ---- Setup ----

.PHONY: setup
setup: ## Check all prerequisites are installed
	@echo "Checking prerequisites..."
	@OK=true; \
	for cmd in jq qemu-system-x86_64 qemu-img docker sshpass ssh scp curl cpio gzip; do \
		if command -v $$cmd >/dev/null 2>&1; then \
			printf "  [OK] %s\n" "$$cmd"; \
		else \
			printf "  [MISSING] %s\n" "$$cmd"; \
			OK=false; \
		fi; \
	done; \
	for cmd in mcopy mkfs.vfat; do \
		if command -v $$cmd >/dev/null 2>&1; then \
			printf "  [OK] %s\n" "$$cmd"; \
		else \
			printf "  [MISSING] %s (install mtools/dosfstools)\n" "$$cmd"; \
			OK=false; \
		fi; \
	done; \
	if [ -f $(ENV_FILE) ]; then \
		printf "  [OK] %s\n" "$(ENV_FILE)"; \
	else \
		printf "  [MISSING] %s (run: cp env.json.example env.json)\n" "$(ENV_FILE)"; \
		OK=false; \
	fi; \
	if [ -d CanvOS/.git ]; then \
		printf "  [OK] %s\n" "CanvOS submodule"; \
	else \
		printf "  [MISSING] %s (run: git submodule update --init)\n" "CanvOS submodule"; \
		OK=false; \
	fi; \
	$$OK && echo "All prerequisites met." || { echo ""; echo "Install missing tools and try again."; exit 1; }

# ---- ISO Download ----

.PHONY: download-iso
download-iso: _require-jfrog ## Download BCM ISO from JFrog to dist/
	@mkdir -p dist
	@if [ -f "$(ISO_PATH)" ]; then \
		echo "ISO already exists: $(ISO_PATH)"; \
		echo "Delete it first to re-download."; \
	else \
		echo "Downloading $(ISO_FILENAME) from $(JFROG_INSTANCE)..."; \
		curl --fail --progress-bar \
			-H "Authorization: Bearer $(JFROG_TOKEN)" \
			-o "$(ISO_PATH)" \
			"https://$(JFROG_INSTANCE)/artifactory/$(JFROG_REPO)/$(ISO_FILENAME)"; \
		echo "Downloaded: $(ISO_PATH)"; \
	fi

# ---- BCM Head Node ----

.PHONY: bcm-prepare
bcm-prepare: _require-bcm-password _require-iso ## Prepare BCM auto-install artifacts from ISO
	src/prepare-bcm-autoinstall.sh --iso "$(ISO_PATH)"

.PHONY: bcm-run
bcm-run: _require-bcm-password _require-iso ## Launch BCM head node VM (auto-install, blocking)
	src/launch-bcm-kvm.sh --auto

.PHONY: bcm-start
bcm-start: _require-bcm-password ## Start existing BCM head node from disk (blocking)
	src/launch-bcm-kvm.sh --disk

.PHONY: bcm-stop
bcm-stop: ## Kill running BCM head node VM
	@pkill -f "qemu-system.*BCM-11.0" 2>/dev/null && echo "BCM VM stopped." || echo "No BCM VM running."

# ---- Kairos Build & Extract ----

.PHONY: kairos-build
kairos-build: ## Build Kairos ISO via CanvOS (requires Docker, takes a while)
	src/build-canvos.sh

.PHONY: kairos-extract
kairos-extract: _require-palette ## Extract PXE artifacts from Kairos ISO
	src/extract-kairos-pxe.sh

.PHONY: bcm-wait
bcm-wait: _require-bcm-password ## Wait for BCM head node to become SSH-ready
	@echo "Waiting for BCM head node SSH (localhost:10022)..."
	@elapsed=0; \
	while ! sshpass -p "$(BCM_PASSWORD)" ssh $(SSH_OPTS) -o ConnectTimeout=3 -p 10022 root@localhost "echo ok" >/dev/null 2>&1; do \
		elapsed=$$((elapsed + 10)); \
		printf "\r  [%dm%02ds] Not ready yet..." $$((elapsed / 60)) $$((elapsed % 60)); \
		sleep 10; \
	done; \
	echo ""; \
	echo "[OK] BCM head node is SSH-ready ($$elapsed seconds)"

.PHONY: kairos-wait
kairos-wait: _require-bcm-password _require-bcm-running ## Wait for Kairos compute node to become reachable
	@echo "Waiting for Kairos compute node..."
	@elapsed=0; \
	while true; do \
		KAIROS_IP=$$(sshpass -p "$(BCM_PASSWORD)" ssh $(SSH_OPTS) -p 10022 root@localhost \
			"grep -oP '10\\.141\\.[0-9]+\\.[0-9]+' /var/lib/misc/dnsmasq.leases 2>/dev/null | head -1" 2>/dev/null); \
		if [ -n "$$KAIROS_IP" ]; then \
			if sshpass -p "$(BCM_PASSWORD)" ssh $(SSH_OPTS) -p 10022 root@localhost \
				"sshpass -p kairos ssh $(SSH_OPTS) -o ConnectTimeout=3 kairos@$$KAIROS_IP 'echo ok'" >/dev/null 2>&1; then \
				echo ""; \
				echo "[OK] Kairos node reachable at $$KAIROS_IP ($$elapsed seconds)"; \
				break; \
			else \
				elapsed=$$((elapsed + 10)); \
				printf "\r  [%dm%02ds] Node $$KAIROS_IP found, waiting for SSH..." $$((elapsed / 60)) $$((elapsed % 60)); \
			fi; \
		else \
			elapsed=$$((elapsed + 10)); \
			printf "\r  [%dm%02ds] No DHCP lease yet..." $$((elapsed / 60)) $$((elapsed % 60)); \
		fi; \
		sleep 10; \
	done

# ---- Kairos Deploy & Test ----

.PHONY: kairos-deploy
kairos-deploy: _require-bcm-password _require-bcm-running ## Upload PXE artifacts to BCM head node
	src/test-kairos-pxe.sh --no-launch

.PHONY: kairos-run
kairos-run: _require-bcm-password _require-bcm-running ## Launch compute node VM (direct kernel boot, blocking)
	src/test-kairos-pxe.sh --skip-upload --direct

.PHONY: kairos-validate
kairos-validate: _require-bcm-password _require-bcm-running ## Validate Kairos node through BCM head node
	src/validate-kairos.sh

# ---- Composite Targets ----

.PHONY: all
all: download-iso bcm-prepare kairos-build kairos-extract ## Full build pipeline (download → prepare → build → extract)

.PHONY: test
test: kairos-deploy kairos-run ## Deploy and boot Kairos compute node

.PHONY: validate
validate: kairos-validate ## Run validation checks on Kairos node

# ---- Cleanup ----

.PHONY: clean
clean: ## Remove build/ artifacts (Kairos ISO + PXE)
	sudo rm -rf build/

.PHONY: clean-bcm
clean-bcm: ## Remove BCM auto-install artifacts (build/.bcm-*)
	sudo rm -f build/.bcm-kernel build/.bcm-rootfs-auto.cgz build/.bcm-init.img

.PHONY: clean-kairos
clean-kairos: ## Remove PXE artifacts only (build/pxe/)
	sudo rm -rf build/pxe/ build/palette-edge-installer.iso build/palette-edge-installer.iso.sha256

.PHONY: clean-disks
clean-disks: ## Remove all QEMU disk images
	rm -f build/*.qcow2

.PHONY: clean-all
clean-all: clean clean-bcm clean-disks ## Remove all generated artifacts including dist/
	rm -rf dist/

.PHONY: reset
reset: clean-all ## Full clean + reset CanvOS submodule to upstream
	@echo "Resetting CanvOS submodule to upstream..."
	cd CanvOS && git checkout . && git clean -fdx
	git submodule update --init
	@echo "Reset complete."

# ---- Help ----

.PHONY: help
help: ## Show this help
	@echo "BCM + Kairos Edge Deployment"
	@echo "============================"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Configuration: $(ENV_FILE) (copy from env.json.example)"
