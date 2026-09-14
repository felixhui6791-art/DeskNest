import AppKit
import CoreGraphics
import OSLog
import ScreenCaptureKit

struct MenuBarCatalogContext {
    let dividerFrame: CGRect
    let isExpanded: Bool
    let screenFrame: CGRect
    let mainDisplayHeight: CGFloat
    let excludedProcessID: pid_t
    let captureIcons: Bool
    let excludedWindowIDs: Set<CGWindowID>

    init(dividerFrame: CGRect, isExpanded: Bool, screenFrame: CGRect,
         mainDisplayHeight: CGFloat, excludedProcessID: pid_t,
         captureIcons: Bool = false, excludedWindowIDs: Set<CGWindowID> = []) {
        self.dividerFrame = dividerFrame
        self.isExpanded = isExpanded
        self.screenFrame = screenFrame
        self.mainDisplayHeight = mainDisplayHeight
        self.excludedProcessID = excludedProcessID
        self.captureIcons = captureIcons
        self.excludedWindowIDs = excludedWindowIDs
    }
}

struct FoldedMenuBarItem: Identifiable {
    var id: CGWindowID { windowID }
    let windowID: CGWindowID
    let pid: pid_t
    let ownerName: String
    let title: String?
    /// Global AppKit coordinates. These may be negative while the section is folded.
    let frame: CGRect
    var icon: NSImage?
    var isActualIcon: Bool

    var displayName: String {
        if let title, !title.isEmpty {
            switch title {
            case "Sound": return "音量"
            case "WiFi": return "Wi-Fi"
            case "Battery": return "电池"
            case "Clock": return "日期与时间"
            case "BentoBox-0": return "控制中心"
            default:
                if title.hasPrefix("Item-"), Int(title.dropFirst(5)) != nil { return "菜单栏项目" }
                return title
            }
        }
        if ownerName == "Control Center" || ownerName == "控制中心" { return "菜单栏项目" }
        return ownerName.isEmpty ? "菜单栏项目" : ownerName
    }
}

/// Public WindowServer metadata supplies candidate items, not an official status-item API.
/// No menus, accessibility trees, screenshots, or permissions are touched by snapshot().
@MainActor
final class MenuBarItemCatalog {
    private static let logger = Logger(subsystem: "com.hui.desknest", category: "MenuBarCatalog")
    private var imageCache = MenuBarIconCache<NSImage>()

    func snapshot(in context: MenuBarCatalogContext) -> [FoldedMenuBarItem] {
        guard let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        if context.captureIcons {
            let liveWindows = rows.reduce(into: [CGWindowID: pid_t]()) { result, row in
                if let id = row[kCGWindowNumber as String] as? CGWindowID,
                   let pid = row[kCGWindowOwnerPID as String] as? pid_t { result[id] = pid }
            }
            imageCache.retainWindows(liveWindows)
        } else {
            imageCache.removeAll()
        }
        return Self.candidates(from: rows, in: context).map { candidate in
            var item = candidate
            let application = NSRunningApplication(processIdentifier: item.pid)
            // Recent macOS versions host third-party status windows in Control Center.
            // Its app icon would misrepresent each individual menu-bar item.
            let isSystemHost = application?.bundleIdentifier == "com.apple.controlcenter"
                || item.ownerName == "Control Center" || item.ownerName == "控制中心"
            if context.captureIcons, let cached = imageCache.image(for: .init(item)) {
                item.icon = cached
                item.isActualIcon = true
            } else {
                item.icon = isSystemHost ? NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: nil)
                    : application?.icon ?? NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: nil)
            }
            return item
        }
    }

    /// Only attempts individual status-item captures after the caller opts in AND
    /// the process already has Screen Recording access. This never requests access.
    /// After 15 seconds images refresh in the background, keeping the last preview
    /// visible. No image is saved to disk or reused after its window disappears.
    func items(in context: MenuBarCatalogContext, forceRefresh: Bool = false,
               onUpdate: (([FoldedMenuBarItem]) -> Void)? = nil) async -> [FoldedMenuBarItem] {
        var items = snapshot(in: context)
        guard context.captureIcons, !Task.isCancelled, CGPreflightScreenCaptureAccess() else { return items }
        let refreshIDs = Set(items.filter {
            forceRefresh || imageCache.needsRefresh(.init($0), at: ProcessInfo.processInfo.systemUptime)
        }.map(\.windowID))
        guard !refreshIDs.isEmpty else { return items }
        var byID: [CGWindowID: SCWindow] = [:]
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { return items }
            byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            let shareableError = error as NSError
            Self.logger.error("stage=shareable-content-failed windowID=0 domain=\(shareableError.domain, privacy: .public) code=\(shareableError.code, privacy: .public)")
        }
        // A bounded number of small, sequential captures avoids opening a stream
        // or retaining a display image just to show a short row of menu icons.
        for index in items.indices.prefix(48) {
            guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { break }
            guard refreshIDs.contains(items[index].windowID) else { continue }
            var image: CGImage?
            if let window = byID[items[index].windowID] {
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                config.width = max(1, Int(ceil(items[index].frame.width * 2)))
                config.height = max(1, Int(ceil(items[index].frame.height * 2)))
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                config.captureResolution = .best
                do {
                    let captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { break }
                    let hasVisiblePixels = Self.containsVisiblePixels(captured)
                    Self.logger.notice("stage=captured windowID=\(items[index].windowID, privacy: .public) visiblePixels=\(hasVisiblePixels, privacy: .public)")
                    if hasVisiblePixels { image = captured }
                } catch {
                    let captureError = error as NSError
                    Self.logger.error("stage=capture-failed windowID=\(items[index].windowID, privacy: .public) domain=\(captureError.domain, privacy: .public) code=\(captureError.code, privacy: .public)")
                    // Hidden windows may not be shareable. Keep the truthful fallback.
                }
            } else {
                Self.logger.notice("stage=shareable-window-missing windowID=\(items[index].windowID, privacy: .public)")
            }
            if image == nil, #available(macOS 15.2, *) {
                image = await captureVisibleRegion(for: items[index], in: context)
            }
            guard !Task.isCancelled, CGPreflightScreenCaptureAccess() else { break }
            guard let image else { continue }
            let icon = NSImage(cgImage: image, size: items[index].frame.size)
            items[index].icon = icon
            items[index].isActualIcon = true
            imageCache.insert(icon, for: .init(items[index]), at: ProcessInfo.processInfo.systemUptime)
            onUpdate?(items)
        }
        return items
    }

    /// Some system-hosted status windows have no independently shareable surface.
    /// macOS 15.2's region API takes global display-space points (Quartz, top-left
    /// origin). Read only the verified visible item's rectangle, never a display.
    @available(macOS 15.2, *)
    private func captureVisibleRegion(for item: FoldedMenuBarItem, in context: MenuBarCatalogContext) async -> CGImage? {
        guard context.isExpanded, !Task.isCancelled, CGPreflightScreenCaptureAccess(),
              let region = Self.visibleCaptureRegion(for: item, in: context,
                                                     metadata: Self.metadata(for: item.windowID)) else { return nil }
        do {
            let image = try await SCScreenshotManager.captureImage(in: region)
            guard !Task.isCancelled, CGPreflightScreenCaptureAccess(),
                  Self.visibleCaptureRegion(for: item, in: context,
                                            metadata: Self.metadata(for: item.windowID)) == region else {
                Self.logger.notice("stage=region-validation-changed windowID=\(item.windowID, privacy: .public)")
                return nil
            }
            let hasVisiblePixels = Self.containsVisiblePixels(image)
            Self.logger.notice("stage=region-captured windowID=\(item.windowID, privacy: .public) visiblePixels=\(hasVisiblePixels, privacy: .public)")
            return hasVisiblePixels ? image : nil
        } catch {
            let captureError = error as NSError
            Self.logger.error("stage=region-capture-failed windowID=\(item.windowID, privacy: .public) domain=\(captureError.domain, privacy: .public) code=\(captureError.code, privacy: .public)")
            return nil
        }
    }

    private static func metadata(for windowID: CGWindowID) -> [[String: Any]] {
        CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]] ?? []
    }

    /// Shared by the pre-capture and post-capture checks. Changed position, owner,
    /// visibility, screen or section invalidates the image instead of caching it.
    static func visibleCaptureRegion(for item: FoldedMenuBarItem, in context: MenuBarCatalogContext,
                                     metadata: [[String: Any]]) -> CGRect? {
        guard context.captureIcons, context.isExpanded, context.screenFrame.contains(item.frame),
              let current = candidates(from: metadata, in: context).first(where: { $0.windowID == item.windowID }),
              current.pid == item.pid, current.frame == item.frame,
              metadata.contains(where: {
                  ($0[kCGWindowNumber as String] as? UInt32) == item.windowID
                      && ($0[kCGWindowOwnerPID as String] as? pid_t) == item.pid
                      && ($0[kCGWindowIsOnscreen as String] as? Bool) == true
              }) else { return nil }
        return CGRect(x: current.frame.minX, y: context.mainDisplayHeight - current.frame.maxY,
                      width: current.frame.width, height: current.frame.height)
    }

    /// Filtering is independent of AppKit application lookup and ScreenCaptureKit,
    /// allowing actual off-screen, multi-display and invalid-metadata cases to be tested.
    static func candidates(from rows: [[String: Any]], in context: MenuBarCatalogContext) -> [FoldedMenuBarItem] {
        let divider = context.dividerFrame
        guard valid(divider), valid(context.screenFrame), context.mainDisplayHeight.isFinite,
              divider.maxY <= context.screenFrame.maxY + 4,
              divider.maxY >= context.screenFrame.maxY - 24,
              divider.height <= 64 else { return [] }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        // A folded divider moves the section to its left, beyond the display edge.
        // Do not clamp those coordinates back into the visible screen.
        let leftLimit = context.isExpanded ? context.screenFrame.minX
            : divider.minX - context.screenFrame.width * 2
        var seen = Set<CGWindowID>()
        return rows.compactMap { row -> FoldedMenuBarItem? in
            guard let level = row[kCGWindowLayer as String] as? Int, level == statusLevel,
                  let number = row[kCGWindowNumber as String] as? UInt32, number != kCGNullWindowID,
                  !context.excludedWindowIDs.contains(number), !seen.contains(number),
                  let pid = row[kCGWindowOwnerPID as String] as? pid_t, pid > 0,
                  pid != context.excludedProcessID,
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let quartzFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary), valid(quartzFrame)
            else { return nil }
            let frame = CGRect(x: quartzFrame.minX, y: context.mainDisplayHeight - quartzFrame.maxY,
                               width: quartzFrame.width, height: quartzFrame.height)
            guard frame.width >= 3, frame.width <= 512, frame.height >= 12, frame.height <= 64,
                  abs(frame.maxY - context.screenFrame.maxY) <= 4,
                  abs(frame.midY - divider.midY) <= 6,
                  frame.maxX <= divider.minX + 1, frame.maxX > leftLimit else { return nil }
            // A visible item on another display with the same menu-bar baseline is
            // not part of this section. Folded items themselves are off screen.
            let isOnScreen = row[kCGWindowIsOnscreen as String] as? Bool ?? false
            if isOnScreen, !frame.intersects(context.screenFrame) { return nil }
            seen.insert(number)
            let rawTitle = (row[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.flatMap { $0.isEmpty ? nil : String($0.prefix(160)) }
            // On macOS 26 these are hosted by Control Center rather than our PID.
            guard !(title?.hasPrefix("DeskNest.") ?? false) else { return nil }
            let owner = (row[kCGWindowOwnerName as String] as? String) ?? "菜单栏项目"
            return FoldedMenuBarItem(windowID: number, pid: pid, ownerName: owner,
                                     title: title, frame: frame, icon: nil, isActualIcon: false)
        }.sorted { lhs, rhs in
            lhs.frame.minX == rhs.frame.minX ? lhs.windowID < rhs.windowID : lhs.frame.minX < rhs.frame.minX
        }
    }

    private static func valid(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0
    }

    /// An off-screen surface can produce a successful but fully transparent image.
    /// Check a small in-memory RGBA rendering before replacing the fallback icon.
    static func containsVisiblePixels(_ image: CGImage) -> Bool {
        let width = min(128, image.width)
        let height = min(64, image.height)
        guard width > 0, height > 0 else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                            | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return stride(from: 3, to: buffer.count, by: 4).contains { buffer[$0] > 0 }
        }
    }
}
