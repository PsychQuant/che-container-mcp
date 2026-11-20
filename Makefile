BINARY_NAME := CheContainerMCP
INSTALL_DIR := $(HOME)/bin

.PHONY: build release release-signed release-signed-local install test test-live clean

build:
	swift build

release:
	swift build -c release

# Canonical release: universal binary, Developer ID + hardened runtime, notarized, packed.
release-signed:
	@: $${DEVELOPER_ID:?DEVELOPER_ID not set (cert SHA-1 or name)}
	@: $${NOTARY_PROFILE:?NOTARY_PROFILE not set (notarytool keychain profile)}
	./scripts/build-mcpb.sh

# Same, but stops before notarization (nothing leaves this machine). For checking the build.
release-signed-local:
	@: $${DEVELOPER_ID:?DEVELOPER_ID not set (cert SHA-1 or name)}
	SKIP_NOTARIZE=1 ./scripts/build-mcpb.sh

install: release
	mkdir -p "$(INSTALL_DIR)"
	cp .build/release/$(BINARY_NAME) "$(INSTALL_DIR)/$(BINARY_NAME)"
	codesign --force --sign - "$(INSTALL_DIR)/$(BINARY_NAME)"
	@echo "Installed: $(INSTALL_DIR)/$(BINARY_NAME) (ad-hoc signed — dev only)"

test:
	swift test

# Runs the integration tests against the real `container` service.
test-live:
	CHE_CONTAINER_LIVE=1 swift test --filter LiveTests

clean:
	swift package clean
