APP_NAME      := copyz
BUNDLE_ID     := app.copyz.mac
VERSION       := 0.1.0
BUILD_DIR     := .build
APP_BUNDLE    := dist/$(APP_NAME).app
EXECUTABLE    := $(BUILD_DIR)/release/$(APP_NAME)
CONTENTS      := $(APP_BUNDLE)/Contents

.PHONY: all build release test ci clean app run install format format-fix

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
app: release
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp $(EXECUTABLE) $(CONTENTS)/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(CONTENTS)/Info.plist
	@printf 'APPL????' > $(CONTENTS)/PkgInfo
	@codesign --force --deep --sign - $(APP_BUNDLE) 2>/dev/null \
		&& echo "signed (ad-hoc; Accessibility will persist across launches)" \
		|| echo "codesign skipped"
	@echo "built $(APP_BUNDLE)"

run: app
	@open $(APP_BUNDLE)

install: app
	@rm -rf ~/Applications/$(APP_NAME).app
	@cp -R $(APP_BUNDLE) ~/Applications/

clean:
	rm -rf $(BUILD_DIR) dist