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

.PHONY: build clean install run

build: ## Build a production release of the server
	cd server && export MIX_ENV=prod && \
		mix deps.get --only prod && \
		mix compile && \
		cd assets && npm ci && cd .. && \
		mix assets.deploy && \
		mix release

clean: ## Remove server build artifacts and node_modules
	rm -rf server/_build server/deps server/assets/node_modules

run: ## Run the built release from server/_build/prod. Run 'make build' first.
	@if [ -z "$${SECRET_KEY_BASE:-}" ]; then \
		echo "SECRET_KEY_BASE not set; generating an ephemeral one (sessions/API tokens will invalidate on next run)." >&2; \
		SECRET_KEY_BASE=$$(openssl rand -base64 48); \
	fi; \
	SECRET_KEY_BASE="$${SECRET_KEY_BASE}" \
		server/_build/prod/rel/termigate/bin/termigate start

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

##@ Container

.PHONY: build-container run-container clean-container

PODMAN ?= podman
CONTAINER_IMAGE ?= termigate:latest
CONTAINER_PORT ?= 8888
CONFIG_DIR ?= ${HOME}/.config/termigate

build-container: ## Build the container image. Override PODMAN or CONTAINER_IMAGE as needed.
	${PODMAN} build --format docker -t ${CONTAINER_IMAGE} -f Containerfile .

run-container: ## Run the container, persisting config to $(CONFIG_DIR). Override SECRET_KEY_BASE, PODMAN, CONTAINER_IMAGE, CONTAINER_PORT, or CONFIG_DIR as needed.
	@mkdir -p "${CONFIG_DIR}"
	@if [ -z "$${SECRET_KEY_BASE:-}" ]; then \
		echo "SECRET_KEY_BASE not set; generating an ephemeral one (sessions/API tokens will invalidate on next run)." >&2; \
		SECRET_KEY_BASE=$$(openssl rand -base64 48); \
	fi; \
	${PODMAN} run --rm -it \
		--name termigate \
		-p ${CONTAINER_PORT}:8888 \
		-e SECRET_KEY_BASE="$${SECRET_KEY_BASE}" \
		-v "${CONFIG_DIR}":/root/.config/termigate:Z \
		${CONTAINER_IMAGE}

clean-container: ## Remove the container image
	-${PODMAN} rmi ${CONTAINER_IMAGE}

##@ Android

.PHONY: android android-clean android-install-debug

# Gradle 8.11.1's bundled Kotlin can't parse Java 25's version string, and the
# Fedora java-21-openjdk package only ships a JRE (no javac). Pin the build to
# a JDK 17/21 if one is available; callers can override ANDROID_JAVA_HOME.
ANDROID_JAVA_HOME ?= $(firstword $(wildcard \
	/usr/lib/jvm/java-21-openjdk-devel \
	/usr/lib/jvm/java-17-openjdk-devel \
	/seconddrive/Downloads/android-studio/jbr \
	/opt/android-studio/jbr \
	$(HOME)/android-studio/jbr \
	/opt/homebrew/opt/openjdk@21 \
	/opt/homebrew/opt/openjdk@17))
ANDROID_SDK_ROOT_GUESS ?= $(firstword $(wildcard \
	$(ANDROID_HOME) \
	$(ANDROID_SDK_ROOT) \
	$(HOME)/Android/Sdk \
	$(HOME)/Library/Android/sdk))
ANDROID_GRADLE_ENV = \
	$(if $(ANDROID_JAVA_HOME),JAVA_HOME="$(ANDROID_JAVA_HOME)") \
	$(if $(ANDROID_SDK_ROOT_GUESS),ANDROID_HOME="$(ANDROID_SDK_ROOT_GUESS)")
ANDROID_DEBUG_PACKAGE = org.tamx.termigate.debug
ADB = $(if $(ANDROID_SDK_ROOT_GUESS),$(ANDROID_SDK_ROOT_GUESS)/platform-tools/adb,adb)

android: ## Build the Android debug APK
	cd android && $(ANDROID_GRADLE_ENV) ./gradlew assembleDebug

android-clean: ## Clean Android build artifacts
	cd android && $(ANDROID_GRADLE_ENV) ./gradlew clean

android-install-debug: ## Install the debug APK to a connected device, replacing any prior install
	-"$(ADB)" uninstall $(ANDROID_DEBUG_PACKAGE)
	cd android && $(ANDROID_GRADLE_ENV) ./gradlew installDebug
