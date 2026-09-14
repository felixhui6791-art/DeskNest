import AppKit
import Combine
import Foundation

enum AppearanceSettings {
    static let transparencyRange: ClosedRange<Double> = 0...0.85
    static let defaultPartitionTransparency = 0.0
    static let defaultMenuBarTransparency = 0.0

    static func normalizedTransparency(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(transparencyRange.upperBound, max(transparencyRange.lowerBound, value))
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var widgets: [DesktopWidget]
    @Published var lastError: String?
    @Published var panelsVisible: Bool {
        didSet { if panelsVisible != oldValue { save() } }
    }
    @Published var snappingEnabled: Bool {
        didSet { if snappingEnabled != oldValue { save() } }
    }
    @Published var avoidNativeWidgets: Bool {
        didSet { if avoidNativeWidgets != oldValue { save() } }
    }
    @Published var menuBarOrganizerEnabled: Bool {
        didSet { if menuBarOrganizerEnabled != oldValue { save() } }
    }
    @Published var menuBarAutoCollapseDelay: Int {
        didSet {
            let normalized = Self.normalizedAutoCollapseDelay(menuBarAutoCollapseDelay)
            if menuBarAutoCollapseDelay != normalized { menuBarAutoCollapseDelay = normalized }
            if menuBarAutoCollapseDelay != oldValue { save() }
        }
    }
    @Published var partitionTransparency: Double {
        didSet {
            let normalized = AppearanceSettings.normalizedTransparency(
                partitionTransparency, fallback: AppearanceSettings.defaultPartitionTransparency
            )
            if partitionTransparency != normalized { partitionTransparency = normalized }
            if partitionTransparency != oldValue { save() }
        }
    }
    @Published var menuBarTransparency: Double {
        didSet {
            let normalized = AppearanceSettings.normalizedTransparency(
                menuBarTransparency, fallback: AppearanceSettings.defaultMenuBarTransparency
            )
            if menuBarTransparency != normalized { menuBarTransparency = normalized }
            if menuBarTransparency != oldValue { save() }
        }
    }
    @Published var partitionGlassTone: GlassTone = .frost {
        didSet { if partitionGlassTone != oldValue { save() } }
    }
    @Published var menuBarGlassTone: GlassTone = .frost {
        didSet { if menuBarGlassTone != oldValue { save() } }
    }
    @Published private(set) var reservedAreas: [ReservedDesktopArea]
    @Published var desktopScanMessage = "拖动或整理布局时会刷新桌面组件的位置。"
    @Published var detectedNativeWidgetCount = 0
    @Published var nativeScanLimited = false

    private let directory: URL
    private let fileURL: URL
    private var isRestoringDocument = false
    private var savingPausedReason: String?

    init(directory: URL? = nil) {
        let storageDirectory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent(AppRelease.current.channel.dataDirectoryName, isDirectory: true)
        self.directory = storageDirectory
        fileURL = storageDirectory.appendingPathComponent("workspace.json")
        widgets = Self.initialWidgets()
        panelsVisible = true
        snappingEnabled = true
        avoidNativeWidgets = true
        menuBarOrganizerEnabled = true
        menuBarAutoCollapseDelay = 0
        partitionTransparency = AppearanceSettings.defaultPartitionTransparency
        menuBarTransparency = AppearanceSettings.defaultMenuBarTransparency
        reservedAreas = []

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            save()
            return
        }

        // Published preference observers also run while restoring values. Wait
        // until every field has loaded before allowing any automatic write.
        isRestoringDocument = true
        defer { isRestoringDocument = false }
        do {
            let data = try Data(contentsOf: fileURL)
            let document = try JSONDecoder().decode(WorkspaceDocument.self, from: data)
            guard document.schemaVersion == 1 else {
                savingPausedReason = "此工作区来自更新版本的栖桌，已保留原文件并暂停保存。请使用相应版本打开。"
                lastError = savingPausedReason
                return
            }
            guard Set(document.widgets.map(\.id)).count == document.widgets.count else {
                throw WorkspaceDataError.duplicateWidgetIDs
            }
            widgets = document.widgets
            panelsVisible = document.panelsVisible
            snappingEnabled = document.snappingEnabled ?? true
            avoidNativeWidgets = document.avoidNativeWidgets ?? true
            menuBarOrganizerEnabled = document.menuBarOrganizerEnabled ?? true
            menuBarAutoCollapseDelay = Self.normalizedAutoCollapseDelay(document.menuBarAutoCollapseDelay ?? 0)
            partitionTransparency = AppearanceSettings.normalizedTransparency(
                document.partitionTransparency ?? AppearanceSettings.defaultPartitionTransparency,
                fallback: AppearanceSettings.defaultPartitionTransparency
            )
            menuBarTransparency = AppearanceSettings.normalizedTransparency(
                document.menuBarTransparency ?? AppearanceSettings.defaultMenuBarTransparency,
                fallback: AppearanceSettings.defaultMenuBarTransparency
            )
            partitionGlassTone = document.partitionGlassTone ?? .frost
            menuBarGlassTone = document.menuBarGlassTone ?? .frost
            reservedAreas = (document.reservedAreas ?? []).filter {
                $0.frame.x.isFinite && $0.frame.y.isFinite
                    && $0.frame.width.isFinite && $0.frame.height.isFinite
                    && $0.frame.width >= 32 && $0.frame.height >= 32
            }
        } catch {
            // Never replace an unreadable document with the initial workspace.
            // Keep the original in place and create a recovery copy when possible.
            let recoveryURL = storageDirectory.appendingPathComponent(
                "workspace.corrupt-\(UUID().uuidString).json"
            )
            let copied = (try? FileManager.default.copyItem(at: fileURL, to: recoveryURL)) != nil
            savingPausedReason = "无法读取工作区，已保留原文件并暂停自动保存。本次更改仅保留在内存中。"
                + (copied ? "恢复副本：\(recoveryURL.path)" : "")
                + " 原因：\(error.localizedDescription)"
            lastError = savingPausedReason
        }
    }

    @discardableResult
    func addWidget(kind: WidgetKind) -> UUID {
        let tint: WidgetTint = switch kind {
        case .files: .sage
        case .note: .clay
        case .clock: .blue
        case .systemMonitor: .blue
        }
        let widget = DesktopWidget(title: kind.title, kind: kind, tint: tint)
        widgets.append(widget)
        save()
        return widget.id
    }

    func updateTitle(id: UUID, title: String) {
        update(id: id) { widget in
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            widget.title = trimmed.isEmpty ? widget.kind.title : title
        }
    }

    func updateGlassTone(id: UUID, tone: GlassTone?) {
        update(id: id) { $0.glassTone = tone }
    }

    func updateTint(id: UUID, tint: WidgetTint) {
        update(id: id) { $0.tint = tint }
    }

    func updateNote(id: UUID, text: String) {
        update(id: id) { $0.note = text }
    }

    func setFrame(id: UUID, frame: WidgetFrame) {
        guard frame.x.isFinite, frame.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { return }
        update(id: id) { $0.frame = frame }
    }

    func toggleWidgetVisibility(id: UUID) {
        update(id: id) { $0.isVisible.toggle() }
    }

    func toggleLock(id: UUID) {
        update(id: id) { $0.isLocked.toggle() }
    }

    func setTitleBarVisible(id: UUID, visible: Bool) {
        update(id: id) { $0.titleBarVisible = visible }
    }

    func addReservedArea(frame: WidgetFrame) {
        guard frame.x.isFinite, frame.y.isFinite, frame.width.isFinite,
              frame.height.isFinite, frame.width >= 32, frame.height >= 32 else { return }
        let titles = Set(reservedAreas.map(\.title))
        var number = 1
        while titles.contains("保留区域 \(number)") { number += 1 }
        reservedAreas.append(ReservedDesktopArea(title: "保留区域 \(number)", frame: frame))
        save()
    }

    func removeReservedArea(id: UUID) {
        guard reservedAreas.contains(where: { $0.id == id }) else { return }
        reservedAreas.removeAll { $0.id == id }
        save()
    }

    func addItems(urls: [URL], to id: UUID) {
        guard let index = widgets.firstIndex(where: { $0.id == id }),
              widgets[index].kind == .files else { return }

        var paths = Set(widgets[index].items.compactMap { $0.resolvedURL }.map(Self.normalizedPath))
        var additions: [DesktopItem] = []
        var failures: [String] = []

        for url in urls {
            guard url.isFileURL else {
                failures.append("仅支持本机文件、文件夹和应用")
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let normalized = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: normalized.path) else {
                failures.append("找不到“\(normalized.lastPathComponent)”")
                continue
            }
            guard paths.insert(Self.normalizedPath(normalized)).inserted else { continue }

            // File references also work on volumes without security-scoped
            // bookmarks; path fallback is appropriate for this unsandboxed app.
            let bookmark = (try? normalized.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )) ?? (try? normalized.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ))
            additions.append(DesktopItem(
                name: normalized.lastPathComponent,
                path: normalized.path,
                bookmarkData: bookmark
            ))
        }

        if !additions.isEmpty {
            widgets[index].items.append(contentsOf: additions)
            save()
        }
        if !failures.isEmpty {
            let importError = failures.joined(separator: "；")
            lastError = lastError.map { "\($0)\n\(importError)" } ?? importError
        }
    }

    func removeItem(id: UUID, from widgetID: UUID) {
        update(id: widgetID) { $0.items.removeAll { $0.id == id } }
    }

    func removeWidget(id: UUID) {
        guard widgets.contains(where: { $0.id == id }) else { return }
        widgets.removeAll { $0.id == id }
        save()
    }

    func openItem(_ item: DesktopItem) {
        guard let url = accessibleURL(for: item) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "找不到“\(item.name)”。文件可能已移动或删除，请重新添加。"
            return
        }
        if !NSWorkspace.shared.open(url) {
            lastError = "无法打开“\(item.name)”，请在 Finder 中检查该文件及其访问权限。"
        }
    }

    func revealItem(_ item: DesktopItem) {
        guard let url = accessibleURL(for: item) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "找不到“\(item.name)”。文件可能已移动或删除，请重新添加。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func accessibleURL(for item: DesktopItem) -> URL? {
        guard let url = item.resolvedURL else {
            lastError = "“\(item.name)”的文件引用无效，请重新添加。"
            return nil
        }
        return url
    }

    private func update(id: UUID, mutation: (inout DesktopWidget) -> Void) {
        guard let index = widgets.firstIndex(where: { $0.id == id }) else { return }
        var widget = widgets[index]
        mutation(&widget)
        guard widget != widgets[index] else { return }
        widgets[index] = widget
        save()
    }

    private func save() {
        guard !isRestoringDocument else { return }
        if let savingPausedReason {
            lastError = savingPausedReason
            return
        }
        do {
            let document = WorkspaceDocument(
                widgets: widgets,
                panelsVisible: panelsVisible,
                snappingEnabled: snappingEnabled,
                avoidNativeWidgets: avoidNativeWidgets,
                menuBarOrganizerEnabled: menuBarOrganizerEnabled,
                menuBarAutoCollapseDelay: menuBarAutoCollapseDelay,
                partitionTransparency: partitionTransparency,
                menuBarTransparency: menuBarTransparency,
                partitionGlassTone: partitionGlassTone,
                menuBarGlassTone: menuBarGlassTone,
                reservedAreas: reservedAreas
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "无法保存工作区，本次更改可能在退出后丢失。\(error.localizedDescription)"
        }
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func normalizedAutoCollapseDelay(_ delay: Int) -> Int {
        [0, 5, 15, 30].contains(delay) ? delay : 0
    }

    private static func initialWidgets() -> [DesktopWidget] {
        [
            DesktopWidget(title: "进行中的项目", kind: .files, tint: .sage),
            DesktopWidget(title: "常用入口", kind: .files, tint: .blue),
        ]
    }
}

private struct WorkspaceDocument: Codable {
    // Older files may contain floatAboveWindows. Ignore that retired preference
    // while retaining the existing groups, file references, and geometry.
    var schemaVersion: Int = 1
    var widgets: [DesktopWidget]
    var panelsVisible: Bool
    var snappingEnabled: Bool?
    var avoidNativeWidgets: Bool?
    var menuBarOrganizerEnabled: Bool?
    var menuBarAutoCollapseDelay: Int?
    var partitionTransparency: Double?
    var menuBarTransparency: Double?
    var partitionGlassTone: GlassTone?
    var menuBarGlassTone: GlassTone?
    var reservedAreas: [ReservedDesktopArea]?
}

private extension WorkspaceDocument {
    // A malformed new preference must not prevent loading existing file groups.
    // Keep the original workspace fields strict so damaged user data is preserved.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        widgets = try values.decode([DesktopWidget].self, forKey: .widgets)
        panelsVisible = try values.decode(Bool.self, forKey: .panelsVisible)
        snappingEnabled = try values.decodeIfPresent(Bool.self, forKey: .snappingEnabled)
        avoidNativeWidgets = try values.decodeIfPresent(Bool.self, forKey: .avoidNativeWidgets)
        reservedAreas = try values.decodeIfPresent([ReservedDesktopArea].self, forKey: .reservedAreas)
        menuBarOrganizerEnabled = try? values.decode(Bool.self, forKey: .menuBarOrganizerEnabled)
        menuBarAutoCollapseDelay = try? values.decode(Int.self, forKey: .menuBarAutoCollapseDelay)
        partitionTransparency = try? values.decode(Double.self, forKey: .partitionTransparency)
        menuBarTransparency = try? values.decode(Double.self, forKey: .menuBarTransparency)
        partitionGlassTone = try? values.decode(GlassTone.self, forKey: .partitionGlassTone)
        menuBarGlassTone = try? values.decode(GlassTone.self, forKey: .menuBarGlassTone)
    }
}

private enum WorkspaceDataError: LocalizedError {
    case duplicateWidgetIDs

    var errorDescription: String? {
        "工作区包含重复的组件标识。"
    }
}
