# EPL labs — top-level build/validate driver.
#
# Two firmware contracts (see plan / docs/technical_specifications.md):
#   - engagement-platform : VS Code devcontainer (replaces MT3000)
#   - drop-mango          : 16MB-fitting Mango image
#
# Per-lab validation lives in each lab's validate.sh.

OPENWRT_VERSION := 23.05.3
TARGET          := ramips
SUBTARGET       := mt76x8
MANGO_PROFILE   := glinet_gl-mt300n-v2

OUTPUT_DIR      := $(CURDIR)/output
MANIFEST        := $(OUTPUT_DIR)/build-manifest.json
DEVCONTAINER    := $(CURDIR)/../.devcontainer

LABS := lab01-hardware-familiarization \
        lab02-imagebuilder-firmware \
        lab03-overlay-deployment \
        lab04-domain-verification \
        lab05-tailscale-mesh \
        lab06-cloudflare-tunnel \
        lab07-first-worker \
        lab08-cloudflare-access \
        lab09-d1-database \
        lab10-kv-r2-storage \
        lab11-chatops-emojichef \
        lab12-drop-device \
        lab13-redirector-relay \
        lab14-capstone

.PHONY: help all engagement-platform drop-mango clean manifest \
        validate-all $(addprefix validate-,$(LABS))

help:
	@echo "EPL — Engagement Platform Labs build targets"
	@echo ""
	@echo "  make engagement-platform   Build the devcontainer image (replaces MT3000)"
	@echo "  make drop-mango            Build the GL.iNet Mango drop firmware"
	@echo "  make all                   Both of the above"
	@echo ""
	@echo "  make validate-<lab>        Run a specific lab's validate.sh"
	@echo "  make validate-all          Run every lab's validate.sh sequentially"
	@echo ""
	@echo "  make manifest              Print the current build-manifest.json"
	@echo "  make clean                 Remove output/"
	@echo ""
	@echo "Pinned: OpenWrt $(OPENWRT_VERSION) / $(TARGET)/$(SUBTARGET) / profile $(MANGO_PROFILE)"

all: engagement-platform drop-mango

engagement-platform: $(OUTPUT_DIR)
	@echo ">>> Building EPL engagement-platform devcontainer image"
	docker build \
	    --build-arg OPENWRT_VERSION=$(OPENWRT_VERSION) \
	    -t epl-engagement-platform:$(OPENWRT_VERSION) \
	    -f $(DEVCONTAINER)/Dockerfile \
	    $(DEVCONTAINER)
	@echo ">>> engagement-platform image built: epl-engagement-platform:$(OPENWRT_VERSION)"

drop-mango: $(OUTPUT_DIR)
	@echo ">>> Building EPL drop-mango firmware (target=$(TARGET)/$(SUBTARGET) profile=$(MANGO_PROFILE))"
	docker compose run --rm imagebuilder \
	    /labs/lab02-imagebuilder-firmware/build-drop-mango.sh
	@echo ">>> drop-mango image built; output in $(OUTPUT_DIR)"
	@ls -la $(OUTPUT_DIR)/targets/$(TARGET)/$(SUBTARGET)/*.bin 2>/dev/null || true

manifest:
	@if [ -f $(MANIFEST) ]; then \
	    cat $(MANIFEST); \
	else \
	    echo "No manifest yet. Run 'make engagement-platform' or 'make drop-mango' first."; \
	fi

clean:
	@rm -rf $(OUTPUT_DIR)
	@echo "Cleaned $(OUTPUT_DIR)"

$(OUTPUT_DIR):
	@mkdir -p $(OUTPUT_DIR)

# Per-lab validators
validate-all: $(addprefix validate-,$(LABS))

$(addprefix validate-,$(LABS)):
	@lab=$(@:validate-%=%); \
	if [ -x $(CURDIR)/$$lab/validate.sh ]; then \
	    echo ">>> validate $$lab"; \
	    $(CURDIR)/$$lab/validate.sh; \
	else \
	    echo "skip $$lab — no validate.sh yet"; \
	fi
