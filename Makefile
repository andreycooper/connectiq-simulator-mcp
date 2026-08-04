SHELL := /bin/sh

RELEASE_BINARY := .build/release/simulator-mcp
RELEASE_RESOURCE_BUNDLE := .build/release/simulator-mcp_SimulatorMCPCore.bundle
INSTALL_ROOT := $(HOME)/.simulator-mcp
INSTALL_DIR := $(INSTALL_ROOT)/bin
INSTALL_BINARY := $(INSTALL_DIR)/simulator-mcp
INSTALL_RESOURCE_BUNDLE := $(INSTALL_DIR)/simulator-mcp_SimulatorMCPCore.bundle
HOST_APP := $(INSTALL_ROOT)/SimulatorMCPHost.app
HOST_CONTENTS := $(HOST_APP)/Contents
HOST_BINARY := $(HOST_CONTENTS)/MacOS/simulator-mcp-host

.PHONY: build test sign install install-host integration clean

build:
	swift build -c release

test:
	swift test

sign: build
	@set -eu; \
	if [ -z "$(SIGNING_IDENTITY)" ] || [ "$(SIGNING_IDENTITY)" = "-" ]; then \
		echo 'SIGNING_IDENTITY must name a persistent code-signing identity; ad-hoc signing (-) is unsupported.' >&2; \
		exit 2; \
	fi; \
	codesign --force --options runtime --timestamp=none --sign "$(SIGNING_IDENTITY)" "$(RELEASE_BINARY)"; \
	codesign --verify --strict --verbose=2 "$(RELEASE_BINARY)"; \
	SIM_SIGNATURE_EXECUTABLE="$(CURDIR)/$(RELEASE_BINARY)" swift test --filter InstalledSignatureVerificationTests

install: sign
	@set -eu; \
	umask 077; \
	mkdir -p "$(INSTALL_DIR)"; \
	tmp="$(INSTALL_BINARY).tmp.$$$$"; \
	tmp_bundle="$(INSTALL_RESOURCE_BUNDLE).tmp.$$$$"; \
	trap 'rm -f "$$tmp"; rm -rf "$$tmp_bundle"' EXIT HUP INT TERM; \
	/usr/bin/install -m 755 "$(RELEASE_BINARY)" "$$tmp"; \
	/usr/bin/ditto "$(RELEASE_RESOURCE_BUNDLE)" "$$tmp_bundle"; \
	codesign --verify --strict --verbose=2 "$$tmp"; \
	rm -rf "$(INSTALL_RESOURCE_BUNDLE)"; \
	mv -f "$$tmp_bundle" "$(INSTALL_RESOURCE_BUNDLE)"; \
	mv -f "$$tmp" "$(INSTALL_BINARY)"; \
	trap - EXIT HUP INT TERM; \
	codesign --verify --strict --verbose=2 "$(INSTALL_BINARY)"; \
	SIM_SIGNATURE_EXECUTABLE="$(INSTALL_BINARY)" swift test --filter InstalledSignatureVerificationTests

install-host: sign
	@set -eu; \
	umask 077; \
	mkdir -p "$(HOST_CONTENTS)/MacOS"; \
	/usr/bin/install -m 755 "$(RELEASE_BINARY)" "$(HOST_BINARY)"; \
	plist="$(HOST_CONTENTS)/Info.plist.tmp.$$$$"; \
	trap 'rm -f "$$plist"' EXIT HUP INT TERM; \
	/usr/bin/plutil -create xml1 "$$plist"; \
	/usr/bin/plutil -insert CFBundleExecutable -string simulator-mcp-host "$$plist"; \
	/usr/bin/plutil -insert CFBundleIdentifier -string dev.simulator-mcp.host "$$plist"; \
	/usr/bin/plutil -insert CFBundleName -string SimulatorMCPHost "$$plist"; \
	/usr/bin/plutil -insert CFBundlePackageType -string APPL "$$plist"; \
	/usr/bin/plutil -insert CFBundleShortVersionString -string 0.3.2 "$$plist"; \
	/usr/bin/plutil -insert LSBackgroundOnly -bool true "$$plist"; \
	mv -f "$$plist" "$(HOST_CONTENTS)/Info.plist"; \
	trap - EXIT HUP INT TERM; \
	codesign --force --deep --options runtime --timestamp=none --sign "$(SIGNING_IDENTITY)" "$(HOST_APP)"; \
	codesign --verify --deep --strict --verbose=2 "$(HOST_APP)"; \
	SIM_SIGNATURE_EXECUTABLE="$(HOST_BINARY)" swift test --filter InstalledSignatureVerificationTests

integration:
	@set -eu; \
	if [ "$${SIM_INTEGRATION:-}" != "1" ]; then \
		echo 'SIM_INTEGRATION=1 is required.' >&2; \
		exit 2; \
	fi; \
	if [ -z "$${SIM_DEVELOPER_KEY:-}" ]; then \
		echo 'SIM_DEVELOPER_KEY must name an existing developer key outside this repository.' >&2; \
		exit 2; \
	fi; \
	test -f "$$SIM_DEVELOPER_KEY"; \
	SIM_INTEGRATION=1 SIM_DEVELOPER_KEY="$$SIM_DEVELOPER_KEY" swift test --filter InstalledServerIntegrationTests

clean:
	swift package clean
