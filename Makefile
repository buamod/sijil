APP_NAME      := copyz
BUNDLE_ID     := app.copyz.mac
VERSION       := 0.1.0
BUILD_DIR     := .build
APP_BUNDLE    := dist/$(APP_NAME).app
EXECUTABLE    := $(BUILD_DIR)/release/$(APP_NAME)
CONTENTS      := $(APP_BUNDLE)/Contents

.PHONY: all build release test clean app run install

all: test app

build:
	swift build

release:
	swift build -c release

test:
	swift test

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