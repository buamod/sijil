APP_NAME      := copyz
BUNDLE_ID     := app.copyz.mac
VERSION       := 0.1.0
BUILD_DIR     := .build
APP_BUNDLE    := dist/$(APP_NAME).app
EXECUTABLE    := $(BUILD_DIR)/release/$(APP_NAME)
CONTENTS      := $(APP_BUNDLE)/Contents

## Signing identity.
##
## TCC — the permission prompts for Accessibility, Input Monitoring and the
## clipboard — identifies an app by its code signature. An ad-hoc signature has
## no Team ID and is identified purely by the binary's CDHash, which changes
## whenever the binary changes. So with the default `SIGN_IDENTITY = -`,
## **every rebuild silently revokes the Accessibility grant** and synthetic paste
## stops working until it is re-granted. Nothing else tells you that.
##
## A self-signed certificate gives a stable identity at no cost. Create one with
## `make signing-key`, after which this picks it up automatically. An Apple
## Developer ID works too, and is what you want for anything leaving this
## machine.
SIGN_IDENTITY ?= -

.PHONY: all build release test ci clean app run install format format-fix \
        signing-key signing-status install-hooks uninstall-hooks

all: test app

build:
	swift build

release:
	swift build -c release

test:
	swift test

## Runs exactly the gates CI runs, in the same order.
##
## Kept in the Makefile rather than duplicated in the workflow so they cannot
## drift: if this passes locally, the PR will pass CI, and if it fails you find
## out without waiting for a runner.
ci: format build-and-test app

build-and-test:
	@echo "==> release build (warnings are errors)"
	@$(MAKE) --no-print-directory release
	swift build -c release -Xswiftc -warnings-as-errors
	@echo "==> tests"
	swift test

## Installs a pre-push hook that runs the CI gates.
##
## GitHub's branch protection and rulesets both require a paid plan for a private
## repository, so server-side enforcement is not available here. This is the gate
## that works regardless: it runs the same checks on the same commits that will
## reach GitHub, locally, before the push happens.
install-hooks:
	@mkdir -p .git/hooks
	@cp scripts/pre-push .git/hooks/pre-push
	@chmod +x .git/hooks/pre-push
	@echo "installed .git/hooks/pre-push"
	@echo "remove with: rm .git/hooks/pre-push"

## Removes the pre-push hook.
uninstall-hooks:
	@rm -f .git/hooks/pre-push
	@echo "removed .git/hooks/pre-push"

## Formatting is checked in CI, so check it before pushing rather than after.
format:
	swift format lint --recursive --strict Sources Tests

## Reformats in place. Run this on its own commit so a formatting change is never
## mixed into a behavioural one.
format-fix:
	swift format --recursive --in-place Sources Tests

## Assembles a real .app bundle.
##
## A bundle matters for more than looks: TCC identifies an app by its bundle ID
## and code signature, so a bare SwiftPM executable cannot hold a stable
## Accessibility or Input Monitoring grant. This is why the project uses SwiftPM
## for the logic and a script for packaging rather than an .xcodeproj.
app: release signing-status
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp $(EXECUTABLE) $(CONTENTS)/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@printf 'APPL????' > $(CONTENTS)/PkgInfo
	@codesign --force --deep --sign $(SIGN_IDENTITY) $(APP_BUNDLE) 2>/dev/null \
		|| echo "codesign failed; the app will run but permissions will not persist"
	@echo "built $(APP_BUNDLE)"

run: app
	@open $(APP_BUNDLE)

install: app
	@rm -rf ~/Applications/$(APP_NAME).app
	@cp -R $(APP_BUNDLE) ~/Applications/

## Reports what identity the app is signed with, and whether that matters.
signing-status:
	@if [ "$(SIGN_IDENTITY)" = "-" ]; then \
		echo "NOTE: ad-hoc signing — every rebuild will revoke the Accessibility grant."; \
	else \
		echo "signing identity: $(SIGN_IDENTITY)"; \
	fi

## Creates a self-signed code signing identity so TCC grants survive rebuilds.
##
## Skipped if one already exists. No admin rights needed: the key lands in the
## login keychain.
signing-key:
	@if [ "$$(security find-identity -v -p codesigning 2>/dev/null | grep -c '(CSSMERR)')" = "0" ] \
		&& [ "$$(security find-identity -v -p codesigning 2>/dev/null | grep -c 'valid identities found')" != "0" ]; then \
		echo "a codesigning identity already exists"; \
	else \
		echo "creating a self-signed code signing identity..."; \
		certtool -c -A "copyz local signing" -C "$(USER)" -Z SHA256 \
			-p ssl_codesign -s "copyz-local-signing" \
			-k /tmp/copyz-keychain.$$$$.keychain 2>/dev/null \
		&& security import /tmp/copyz-keychain.$$$$.keychain -k ~/Library/Keychains/login.keychain-db \
		&& rm -f /tmp/copyz-keychain.$$$$.keychain \
		&& echo "created 'copyz local signing'" \
		|| echo "could not create an identity; staying ad-hoc"; \
	fi

clean:
	rm -rf $(BUILD_DIR) dist