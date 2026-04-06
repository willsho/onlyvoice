APP_NAME = OnlyVoice
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app
INSTALL_DIR = /Applications

.PHONY: build run install clean

build:
	swift build -c release
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	@cp Info.plist $(APP_BUNDLE)/Contents/
	@codesign --force --deep --sign - \
		--entitlements OnlyVoice.entitlements \
		--options runtime \
		$(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

run: build
	@open $(APP_BUNDLE)

install: build
	@cp -R $(APP_BUNDLE) $(INSTALL_DIR)/
	@echo "Installed to $(INSTALL_DIR)/$(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)
	rm -rf .build
