# termigate Makefile

INSTALL_DIR := /opt/termigate
SERVICE_FILE := /etc/systemd/system/termigate.service

## ── Server ──────────────────────────────────────────────

.PHONY: build clean install

build:
	cd server && export MIX_ENV=prod && \
		mix deps.get --only prod && \
		mix compile && \
		cd assets && npm ci && cd .. && \
		mix assets.deploy && \
		mix release

clean:
	rm -rf server/_build server/deps server/assets/node_modules

install: build
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

## ── Android ─────────────────────────────────────────────

.PHONY: android android-clean android-install-debug

android:
	cd android && ./gradlew assembleDebug

android-clean:
	cd android && ./gradlew clean

android-install-debug:
	cd android && ./gradlew installDebug
