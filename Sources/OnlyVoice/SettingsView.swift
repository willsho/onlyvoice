import AppKit
import Observation
import SwiftUI

// MARK: - Tabs

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case provider
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .provider: "Provider"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .provider: "antenna.radiowaves.left.and.right"
        case .about: "info.circle"
        }
    }
}

// MARK: - Navigation state (singleton so the menu bar can jump to a tab)

@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selectedTab: SettingsTab? = .provider
    private init() {}
}

// MARK: - Root view

struct SettingsView: View {
    @State private var navigation = SettingsNavigation.shared
    @State private var navigationHistory: [SettingsTab] = [.provider]
    @State private var historyIndex = 0
    @State private var isHistoryNavigation = false

    private var activeTab: SettingsTab { navigation.selectedTab ?? .provider }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebarView(selectedTab: $navigation.selectedTab)
                .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetailView(tab: activeTab)
        }
        .navigationTitle("Settings")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 640, minHeight: 460)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!canGoBack)
                Button { goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!canGoForward)
            }
        }
        .onChange(of: navigation.selectedTab) { _, _ in recordNavigation() }
    }

    // MARK: - Back/forward history

    private var canGoBack: Bool { historyIndex > 0 }
    private var canGoForward: Bool { historyIndex < navigationHistory.count - 1 }

    private func goBack() {
        guard canGoBack else { return }
        isHistoryNavigation = true
        historyIndex -= 1
        navigation.selectedTab = navigationHistory[historyIndex]
        DispatchQueue.main.async { isHistoryNavigation = false }
    }

    private func goForward() {
        guard canGoForward else { return }
        isHistoryNavigation = true
        historyIndex += 1
        navigation.selectedTab = navigationHistory[historyIndex]
        DispatchQueue.main.async { isHistoryNavigation = false }
    }

    private func recordNavigation() {
        guard !isHistoryNavigation, let tab = navigation.selectedTab else { return }
        if navigationHistory.last == tab { return }
        if historyIndex < navigationHistory.count - 1 {
            navigationHistory = Array(navigationHistory.prefix(historyIndex + 1))
        }
        navigationHistory.append(tab)
        historyIndex = navigationHistory.count - 1
    }
}

// MARK: - Sidebar

private struct SettingsSidebarView: View {
    @Binding var selectedTab: SettingsTab?

    var body: some View {
        List(selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    Image(systemName: tab.systemImage)
                }
                .foregroundStyle(.primary)
                .tag(tab)
            }
        }
        .listStyle(.sidebar)
        .scrollEdgeEffectStyleSoftIfAvailable()
        .navigationTitle("Settings")
    }
}

// MARK: - Detail routing

private struct SettingsDetailView: View {
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettingsPane()
            case .provider: ProviderSettingsPane()
            case .about: AboutSettingsPane()
            }
        }
        .navigationTitle(tab.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - macOS 26 availability helper

extension View {
    @ViewBuilder
    func scrollEdgeEffectStyleSoftIfAvailable() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}
