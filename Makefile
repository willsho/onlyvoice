APP_NAME = OnlyVoice
BUILD_DIR = .build/release
APP_BUNDLE = $(APP_NAME).app
INSTALL_DIR = /Applications
ICON_SCRIPT = Tools/generate_app_icon.swift
ICONSET_DIR = .build/AppIcon.iconset
ICON_FILE = .build/AppIcon.icns
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DIST_DIR = dist
DMG_NAME = $(APP_NAME)-$(VERSION).dmg
DMG_PATH = $(DIST_DIR)/$(DMG_NAME)
DMG_STAGING_DIR = .build/dmg

# 代码签名身份。
# - 默认 ad-hoc（-）：这是提交进仓库的值，CI / 他人 clone 都能直接 build。
# - 本地开发：在 Makefile.local（已 git 忽略）里把 SIGN_IDENTITY 设为稳定证书，
#   让「辅助功能」授权在 rebuild 后保留（ad-hoc 每次 cdhash 变会丢授权）。
# - 发布（make dmg）：见下方 target，强制 ad-hoc，不把开发者身份嵌入对外产物。
-include Makefile.local
SIGN_IDENTITY ?= -

.PHONY: build run install clean icon dmg

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
	@cp Sources/OnlyVoice/Resources/*.wav $(APP_BUNDLE)/Contents/Resources/
	@codesign --force --deep --sign "$(SIGN_IDENTITY)" \
		--entitlements OnlyVoice.entitlements \
		--options runtime \
		$(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE) (signed: $(SIGN_IDENTITY))"

# 发布产物强制 ad-hoc 签名：target-specific 变量会传播到前置依赖 build，
# 即使本地有 Makefile.local 也不影响对外 DMG。如需指定身份：make dmg SIGN_IDENTITY="..."
dmg: SIGN_IDENTITY := -
dmg: build
	@rm -rf $(DMG_STAGING_DIR) $(DMG_PATH)
	@mkdir -p $(DMG_STAGING_DIR) $(DIST_DIR)
	@cp -R $(APP_BUNDLE) $(DMG_STAGING_DIR)/
	@ln -s /Applications $(DMG_STAGING_DIR)/Applications
	@hdiutil create -volname "$(APP_NAME)" \
		-srcfolder $(DMG_STAGING_DIR) \
		-ov -format UDZO \
		$(DMG_PATH)
	@rm -rf $(DMG_STAGING_DIR)
	@echo "Built $(DMG_PATH)"

run: build
	@open $(APP_BUNDLE)

install: build
	@cp -R $(APP_BUNDLE) $(INSTALL_DIR)/
	@echo "Installed to $(INSTALL_DIR)/$(APP_BUNDLE)"

clean:
	swift package clean
	rm -rf $(APP_BUNDLE)
	rm -rf .build
