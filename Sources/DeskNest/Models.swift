import Foundation
import SwiftUI

enum WidgetKind: String, Codable, CaseIterable {
    case files
    case note
    case clock
    case systemMonitor

    var title: String {
        switch self {
        case .files: "文件分区"
        case .note: "便签"
        case .clock: "时钟"
        case .systemMonitor: "系统监控"
        }
    }
}

enum WidgetTint: String, Codable, CaseIterable {
    case sage
    case clay
    case blue
    case lavender

    var title: String {
        switch self {
        case .sage: "鼠尾草"
        case .clay: "陶土"
        case .blue: "雾蓝"
        case .lavender: "薰衣草"
        }
    }

    var color: Color {
        switch self {
        case .sage: Color(red: 0.47, green: 0.60, blue: 0.50)
        case .clay: Color(red: 0.77, green: 0.51, blue: 0.39)
        case .blue: Color(red: 0.40, green: 0.57, blue: 0.70)
        case .lavender: Color(red: 0.61, green: 0.52, blue: 0.73)
        }
    }
}

struct DesktopItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var path: String
    var bookmarkData: Data? = nil

    /// A bookmark can keep a reference valid when Finder moves or renames a file.
    /// The stored path is a fallback for volumes that do not support bookmarks.
    var resolvedURL: URL? {
        if let bookmarkData {
            var stale = false
            if let url = (try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )) ?? (try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )) {
                return url
            }
        }
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}

struct WidgetFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct ReservedDesktopArea: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var frame: WidgetFrame
}

struct DesktopWidget: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var kind: WidgetKind
    var tint: WidgetTint = .sage
    var glassTone: GlassTone? = nil
    var items: [DesktopItem] = []
    var note: String = ""
    var frame: WidgetFrame? = nil
    var isVisible: Bool = true
    var isLocked: Bool = false
    // Optional on disk so existing workspaces keep their visible title bars.
    var titleBarVisible: Bool? = nil
    var showsTitleBar: Bool { titleBarVisible ?? true }
}
