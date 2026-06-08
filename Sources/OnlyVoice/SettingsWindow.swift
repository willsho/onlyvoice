import AppKit
import SwiftUI

/// 设置窗口控制器。用 `.fullSizeContentView` 创建 NSWindow，让 macOS 26 渲染
/// liquid glass 圆角窗体；内容是一个 SwiftUI 的 NavigationSplitView（侧栏 + 详情）。
///
/// 用法：`SettingsWindowController.show(tab: .provider)`
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?

    /// 显示设置窗口，可选跳转到指定分页。
    static func show(tab: SettingsTab? = nil) {
        if let tab {
            SettingsNavigation.shared.selectedTab = tab
        }
        if shared == nil {
            shared = SettingsWindowController()
        }
        shared?.showWindow(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 680, height: 520)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configureWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureWindow() {
        guard let window else { return }
        window.title = "Settings"
        window.titleVisibility = .visible
        window.toolbarStyle = .automatic
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("OnlyVoiceSettingsWindow")
        window.minSize = NSSize(width: 620, height: 460)
        window.center()
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SettingsView())
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // 菜单栏 app（LSUIElement）：临时切到 .regular 让窗口拿到键盘焦点。
        AppActivationPolicy.enter()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        AppActivationPolicy.leave()
        Self.shared = nil
    }
}

/// 引用计数式的激活策略管理：有窗口时切 `.regular`（前台 + 临时 Dock 图标），
/// 全部关闭后切回 `.accessory`（纯菜单栏，无 Dock 图标）。
enum AppActivationPolicy {
    private static var count = 0

    static func enter() {
        count += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func leave() {
        count = max(0, count - 1)
        guard count == 0 else { return }
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
