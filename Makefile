# termigate Makefile

INSTALL_DIR := /opt/termigate
SERVICE_FILE := /etc/systemd/system/termigate.service

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make \033[36m<target>\033[0m\n\nTargets:\n"} \
		/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Server

.PHONY: build clean install

build: ## Build a production release of the server
	cd server && export MIX_ENV=prod && \
		mix deps.get --only prod && \
		mix compile && \
		cd assets && npm ci && cd .. && \
		mix assets.deploy && \
		mix release

clean: ## Remove server build artifacts and node_modules
	rm -rf server/_build server/deps server/assets/node_modules

install: build ## Install release to $(INSTALL_DIR) and systemd unit
	sudo rm -rf $(INSTALL_DIR)
	sudo mkdir -p $(INSTALL_DIR)
	sudo cp -r server/_build/prod/rel/termigate/* $(INSTALL_DIR)/
	sudo cp deploy/termigate.service $(SERVICE_FILE)
	sudo systemctl daemon-reload
	@echo ""
	@echo "Installed to $(INSTALL_DIR)"
	@echo "Service file installed to $(SERVICE_FILE)"
	@echo ""
	@echo "  sudo systemctl enable termigate"
	@echo "  sudo systemctl start termigate"

##@ Android

.PHONY: android android-clean android-install-debug

android: ## Build the Android debug APK
	cd android && ./gradlew assembleDebug

android-clean: ## Clean Android build artifacts
	cd android && ./gradlew clean

android-install-debug: ## Install the debug APK to a connected device
	cd android && ./gradlew installDebug
