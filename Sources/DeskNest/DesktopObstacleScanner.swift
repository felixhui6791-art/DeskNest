import AppKit
import CoreGraphics

struct DesktopObstacle: Identifiable, Equatable {
    let id: String
    /// Global AppKit coordinates: origin at the main display's bottom-left.
    let frame: CGRect
}

struct DesktopScanResult {
    let obstacles: [DesktopObstacle]
    let message: String
    let isLimited: Bool
}

/// A conservative, best-effort detector, not a WidgetKit layout API.
///
/// Window geometry is available without Screen Recording or Accessibility access.
/// We never read window titles or capture pixels. WidgetKit does not expose other
/// apps' desktop widget positions, so system host/layer matching remains a
/// heuristic and every result is explicitly marked as limited.
@MainActor
enum DesktopObstacleScanner {
    struct WindowMetadata {
        let id: CGWindowID
        let ownerPID: pid_t
        let bundleIdentifier: String?
        let cgFrame: CGRect
        let layer: Int
        let alpha: CGFloat
        let isOnScreen: Bool
    }

    static func scan() -> DesktopScanResult {
        let screens = NSScreen.screens
        guard let primaryScreen = screens.first else {
            return DesktopScanResult(
                obstacles: [], message: "暂时无法读取屏幕布局，已跳过原生组件识别。", isLimited: true
            )
        }
        // Do not use excludeDesktopElements: that also excludes the geometry we need.
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]] else {
            return DesktopScanResult(
                obstacles: [], message: "暂时无法读取桌面窗口位置，已跳过原生组件识别。", isLimited: true
            )
        }
        var bundles: [pid_t: String] = [:]
        let metadata = windows.compactMap { window -> WindowMetadata? in
            guard let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            let bundle = bundles[pid] ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            if let bundle { bundles[pid] = bundle }
            return WindowMetadata(
                id: id, ownerPID: pid, bundleIdentifier: bundle, cgFrame: frame,
                layer: layer,
                alpha: (window[kCGWindowAlpha as String] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 1,
                isOnScreen: (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
            )
        }
        return analyze(
            metadata, screenFrames: screens.map(\.frame),
            primaryScreenHeight: primaryScreen.frame.height,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
    }

    /// Pure geometry/filtering boundary, also used to test unusual display layouts.
    static func analyze(
        _ windows: [WindowMetadata], screenFrames: [CGRect],
        primaryScreenHeight: CGFloat, ownPID: pid_t,
        desktopIconLevel: Int = Int(CGWindowLevelForKey(.desktopIconWindow))
    ) -> DesktopScanResult {
        var obstacles: [DesktopObstacle] = []
        for window in windows {
            // Exact system host and the observed desktop-widget layer on this Mac.
            // Normal-layer Notification Center panels, notifications, Finder icons,
            // desktop backdrops, menus, and other apps are intentionally excluded.
            // If Apple changes the host/layer, prefer a clear limited result to
            // reserving unrelated desktop space using a broad application match.
            guard window.ownerPID != ownPID,
                  window.bundleIdentifier == "com.apple.notificationcenterui",
                  window.layer == desktopIconLevel + 2,
                  window.isOnScreen, window.alpha.isFinite, window.alpha > 0.01,
                  validFrame(window.cgFrame), primaryScreenHeight.isFinite else { continue }
            let frame = CGRect(
                x: window.cgFrame.minX,
                y: primaryScreenHeight - window.cgFrame.maxY,
                width: window.cgFrame.width, height: window.cgFrame.height
            )
            guard plausibleWidgetFrame(frame, screens: screenFrames) else { continue }
            // Some system transitions briefly expose duplicate surface windows.
            guard !obstacles.contains(where: { approximatelyEqual($0.frame, frame) }) else { continue }
            obstacles.append(DesktopObstacle(id: "native-\(window.ownerPID)-\(window.id)", frame: frame))
        }
        let message = obstacles.isEmpty
            ? "未识别到原生组件区域；系统可能未公开位置，不能据此判断桌面为空。"
            : "发现 \(obstacles.count) 个原生组件候选区域，将据此避让；识别可能有遗漏。"
        return DesktopScanResult(obstacles: obstacles, message: message, isLimited: true)
    }

    private static func validFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.size.width.isFinite && frame.size.height.isFinite
            && frame.size.width > 0 && frame.size.height > 0
    }

    private static func plausibleWidgetFrame(_ frame: CGRect, screens: [CGRect]) -> Bool {
        // Geometric checks are a second guard, not evidence of widget identity.
        guard frame.width >= 100, frame.height >= 100,
              frame.width <= 900, frame.height <= 900,
              max(frame.width, frame.height) / min(frame.width, frame.height) <= 4.5 else { return false }
        return screens.contains { screen in
            guard validFrame(screen), frame.width < screen.width * 0.85,
                  frame.height < screen.height * 0.85 else { return false }
            let intersection = screen.intersection(frame)
            guard !intersection.isNull else { return false }
            let area = frame.width * frame.height
            return intersection.width * intersection.height >= area * 0.9
                && area < screen.width * screen.height * 0.45
        }
    }

    private static func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.5 && abs(lhs.minY - rhs.minY) < 0.5
            && abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
    }
}
