import AppKit
import SwiftUI

/// Presentation destinations deliberately remain separate from scan categories.
enum CleanerWorkspace: String, CaseIterable, Identifiable {
    case overview, space, files, applications, xcode, caches, cloud

    var id: Self { self }
    var title: String {
        switch self {
        case .overview: L("overview")
        case .space: L("space")
        case .files: L("workspaceFiles")
        case .applications: L("workspaceApplications")
        case .xcode: L("developerCache")
        case .caches: L("systemCache")
        case .cloud: L("icloud")
        }
    }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .space: "chart.pie"
        case .files: "folder"
        case .applications: "app.badge"
        case .xcode: "hammer"
        case .caches: "folder.badge.gearshape"
        case .cloud: "icloud"
        }
    }
    init(category: ScanCategory) {
        switch category {
        case .overview: self = .overview
        case .space: self = .space
        case .downloads, .large, .duplicates: self = .files
        case .uninstall, .orphans: self = .applications
        case .developerCache: self = .xcode
        case .systemCache: self = .caches
        case .icloud: self = .cloud
        }
    }
}

@MainActor
final class WorkspaceNavigation: ObservableObject {
    @Published private(set) var fileCategory: ScanCategory = .downloads
    @Published private(set) var applicationCategory: ScanCategory = .uninstall

    func remember(_ category: ScanCategory) {
        switch category {
        case .downloads, .large, .duplicates: fileCategory = category
        case .uninstall, .orphans: applicationCategory = category
        default: break
        }
    }

    func category(for workspace: CleanerWorkspace) -> ScanCategory {
        switch workspace {
        case .overview: .overview
        case .space: .space
        case .files: fileCategory
        case .applications: applicationCategory
        case .xcode: .developerCache
        case .caches: .systemCache
        case .cloud: .icloud
        }
    }
}

enum WorkspaceStyle {
    static let pageInset: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
    static let cornerRadius: CGFloat = 10
}

struct WorkspaceHeading<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actions
        }
    }
}

struct WorkspaceMetric: View {
    let title: LocalizedStringKey
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3).foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .workspaceCard()
    }
}

struct WorkspaceStatus: View {
    let title: String
    let symbol: String
    var warning = false

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(warning ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

struct WorkspaceActionBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            content
                .padding(.horizontal, WorkspaceStyle.pageInset)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
    }
}

struct WorkspaceFilterBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .controlSize(.regular)
    }
}

struct WorkspaceSheet<Content: View>: View {
    @EnvironmentObject private var preferences: AppPreferences
    let title: String
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                Button("done", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .hoverHighlight()
            }
            .padding(20)
            Divider()
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
        .frame(minWidth: 600, idealWidth: 680, minHeight: 400, idealHeight: 560)
        .environment(\.locale, preferences.language.locale)
    }
}

private struct WorkspaceCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: WorkspaceStyle.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: WorkspaceStyle.cornerRadius)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func workspaceCard() -> some View { modifier(WorkspaceCardModifier()) }
}
