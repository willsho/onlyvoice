APP_NAME = OnlyVoice
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app
INSTALL_DIR = /Applications
ICON_SCRIPT = Tools/generate_app_icon.swift
ICONSET_DIR = .build/AppIcon.iconset
ICON_FILE = .build/AppIcon.icns

.PHONY: build run install clean icon

icon:
	@rm -rf $(ICONSET_DIR) $(ICON_FILE)
	@swift $(ICON_SCRIPT) $(ICONSET_DIR) $(ICON_FILE)
	@echo "Generated $(ICON_FILE)"

build: icon
	swift build -c release
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	@cp Info.plist $(APP_BUNDLE)/Contents/
	@cp $(ICON_FILE) $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
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
