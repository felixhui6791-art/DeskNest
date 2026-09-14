import AppKit
import ApplicationServices
import CoreGraphics
import OSLog

enum MenuBarItemActivationResult: Equatable, Sendable {
    /// The application accepted its item's accessibility action. It may show a
    /// custom panel rather than a menu; this does not assert that a menu appeared.
    case performed
    /// Synchronous menus may begin tracking before AX can acknowledge the
    /// action. Keep the original bar available and do not reopen the tray.
    case unconfirmed(String)
    case needsAccessibility
    case unavailable(String)
}

/// Invokes only the status item selected by the user, through public AX APIs.
/// No mouse events, window repositioning, or application-launch fallback is used.
@MainActor
final class MenuBarItemActivator {
    nonisolated private static let logger = Logger(subsystem: "com.hui.desknest", category: "MenuBarItemActivation")

    func activate(windowID: CGWindowID, ownerPID: pid_t) async -> MenuBarItemActivationResult {
        guard AXIsProcessTrusted() else {
            Self.trace("permission-required")
            return .needsAccessibility
        }
        Self.trace("activation-start")
        // On recent macOS versions Control Center can own the backing windows
        // for other apps' status items. AX ownership must therefore be resolved
        // independently from the WindowServer owner PID.
        let pids = NSWorkspace.shared.runningApplications.map(\.processIdentifier)
            .filter { $0 > 0 && $0 != ProcessInfo.processInfo.processIdentifier }
        let visibleAreas = NSScreen.screens.flatMap { screen -> [CGRect] in
            let sides = [screen.auxiliaryTopLeftArea, screen.auxiliaryTopRightArea].compactMap { $0 }
                .filter { !$0.isEmpty }
            return sides.isEmpty ? (screen.safeAreaInsets.top > 0 ? [] : [screen.frame]) : sides
        }
        let task = Task.detached(priority: .userInitiated) {
            Self.perform(windowID: windowID, ownerPID: ownerPID, applicationPIDs: pids,
                         visibleAreas: visibleAreas)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func perform(windowID: CGWindowID, ownerPID: pid_t,
                                            applicationPIDs: [pid_t], visibleAreas: [CGRect]) -> MenuBarItemActivationResult {
        guard AXIsProcessTrusted() else {
            trace("worker-permission-required")
            return .needsAccessibility
        }
        guard let initialFrame = currentFrame(windowID: windowID, ownerPID: ownerPID) else {
            trace("initial-window-unavailable")
            return .unavailable("这个菜单栏项目已发生变化，请刷新后重试。")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        let hitItem = hitTestItem(windowID: windowID, ownerPID: ownerPID, expectedFrame: initialFrame,
                                  visibleAreas: visibleAreas, deadline: deadline)
        var matches: [AXUIElement] = hitItem.map { [$0] } ?? []
        var pids = Array(Set(applicationPIDs))
        // This helps older macOS versions without assuming that ownership holds.
        pids.sort { left, right in
            if left == right { return false }
            if left == ownerPID { return true }
            if right == ownerPID { return false }
            return left < right
        }
        // A validated system hit-test identifies the topmost status item directly;
        // only an unsuccessful hit-test needs the conservative global fallback.
        for pid in (hitItem == nil ? pids : []) {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else {
                trace(Task.isCancelled ? "application-scan-cancelled" : "application-scan-deadline")
                return .unavailable("菜单栏项目响应较慢，请稍后重试，或在原菜单栏中打开。")
            }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.08)
            var extrasValue: CFTypeRef?
            let extrasResult = AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &extrasValue)
            switch extrasResult {
            case .success: break
            case .attributeUnsupported, .noValue, .notImplemented, .invalidUIElement: continue
            default:
                // An unresponsive app might own the same backing status-item
                // position. Do not claim uniqueness after an incomplete scan.
                trace("extras-query-aborted", error: extrasResult)
                return .unavailable("有应用暂时无法响应菜单栏查询，请稍后重试。")
            }
            guard let extrasValue, CFGetTypeID(extrasValue) == AXUIElementGetTypeID() else { continue }
            let extras = unsafeDowncast(extrasValue, to: AXUIElement.self)
            guard let children = children(of: extras) else {
                trace("children-scan-aborted")
                return .unavailable("暂时无法完整读取菜单栏图标，请稍后重试。")
            }
            // Only direct status-item children. Never inspect opened menus,
            // their titles, or any other application content.
            guard children.count <= 128 else {
                trace("children-count-limit")
                return .unavailable("这个应用提供的菜单栏项目过多，请在原菜单栏中打开。")
            }
            for child in children {
                guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else {
                    trace(Task.isCancelled ? "item-scan-cancelled" : "item-scan-deadline")
                    return .unavailable("菜单栏项目响应较慢，请稍后重试，或在原菜单栏中打开。")
                }
                guard let frame = accessibilityFrame(of: child),
                      MenuBarItemActivationGeometry.matches(frame, target: initialFrame) else { continue }
                if !matches.contains(where: { CFEqual($0, child) }) { matches.append(child) }
                guard matches.count == 1 else {
                    trace("ambiguous-position-match")
                    return .unavailable("无法唯一确定这个图标，请在原菜单栏中打开。")
                }
            }
        }
        guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else {
            trace(Task.isCancelled ? "matching-cancelled" : "matching-deadline")
            return .unavailable("本次操作已取消，请重试。")
        }
        guard let item = matches.first else {
            trace("matching-no-item")
            return .unavailable("这个图标暂不支持从折叠区打开，请在原菜单栏中打开。")
        }
        // Revalidate both independently sourced positions after the asynchronous
        // app queries. A status item can move or disappear while being resolved.
        guard let finalFrame = currentFrame(windowID: windowID, ownerPID: ownerPID,
                                            visibleAreas: hitItem == nil ? nil : visibleAreas),
              MenuBarItemActivationGeometry.matches(finalFrame, target: initialFrame),
              let itemFrame = accessibilityFrame(of: item),
              MenuBarItemActivationGeometry.matches(itemFrame, target: finalFrame) else {
            trace("position-revalidation-failed")
            return .unavailable("图标的位置刚刚改变，请重试。")
        }
        var actionNames: CFArray?
        let actionNamesResult = AXUIElementCopyActionNames(item, &actionNames)
        guard actionNamesResult == .success,
              let actions = actionNames as? [String] else {
            trace("action-names-unavailable", error: actionNamesResult)
            return .unavailable("这个图标没有提供可用的打开操作，请在原菜单栏中打开。")
        }
        guard let action = MenuBarItemActivationGeometry.preferredAction(actions) else {
            trace("opening-action-unsupported")
            return .unavailable("这个图标暂不支持从折叠区打开，请在原菜单栏中打开。")
        }
        guard !Task.isCancelled, AXIsProcessTrusted() else {
            trace(Task.isCancelled ? "dispatch-cancelled" : "dispatch-permission-required")
            return AXIsProcessTrusted() ? .unavailable("本次操作已取消。") : .needsAccessibility
        }
        AXUIElementSetMessagingTimeout(item, 0.25)
        var result = AXUIElementPerformAction(item, action as CFString)
        trace(action == kAXPressAction ? "press-result" : "show-menu-result", error: result)
        // A definite unsupported response means Press was not performed. Only
        // this response permits the alternate action explicitly exposed by AX.
        if MenuBarItemActivationGeometry.shouldTryShowMenu(after: result, attemptedAction: action,
                                                           advertisedActions: actions),
           !Task.isCancelled, AXIsProcessTrusted() {
            result = AXUIElementPerformAction(item, kAXShowMenuAction as CFString)
            trace("show-menu-fallback-result", error: result)
        }
        // Never repeat an action after cannotComplete: the target may already
        // have opened a synchronous menu, and repeating would close it again.
        if !AXIsProcessTrusted() { return .needsAccessibility }
        return MenuBarItemActivationGeometry.actionResult(result)
    }

    /// The SDK specifies top-left screen coordinates and topmost-window hit
    /// testing for the system-wide AX element. Only its target's parent chain is
    /// read; no app menu children, titles, or unrelated applications are queried.
    nonisolated private static func hitTestItem(windowID: CGWindowID, ownerPID: pid_t,
                                                expectedFrame: CGRect, visibleAreas: [CGRect],
                                                deadline: TimeInterval) -> AXUIElement? {
        guard !Task.isCancelled,
              let before = currentFrame(windowID: windowID, ownerPID: ownerPID, visibleAreas: visibleAreas),
              MenuBarItemActivationGeometry.matches(before, target: expectedFrame) else {
            trace("hit-test-target-not-visible")
            return nil
        }
        let point = MenuBarItemActivationGeometry.quartzCenter(of: before,
            mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        // A system-wide timeout is process-local. Limit this one query, then
        // restore the default; every subsequently queried element has its own limit.
        AXUIElementSetMessagingTimeout(system, 0.15)
        let result = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        AXUIElementSetMessagingTimeout(system, 0)
        guard result == .success, let hit else {
            trace("hit-test-query-failed", error: result)
            return nil
        }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID > 0 else {
            trace("hit-test-owner-unavailable")
            return nil
        }
        let application = AXUIElementCreateApplication(hitPID)
        guard let extras = elementAttribute(application, attribute: kAXExtrasMenuBarAttribute) else {
            trace("hit-test-extras-unavailable")
            return nil
        }
        var node = hit
        var candidate: AXUIElement?
        // Include the hit element and at most four parent steps. Requiring the
        // owning app's extras bar excludes ordinary File/Edit menu bar items.
        for depth in 0...4 {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else {
                trace("hit-test-cancelled-or-deadline")
                return nil
            }
            if CFEqual(node, extras) {
                guard let candidate,
                      let after = currentFrame(windowID: windowID, ownerPID: ownerPID, visibleAreas: visibleAreas),
                      MenuBarItemActivationGeometry.matches(after, target: before),
                      let candidateFrame = accessibilityFrame(of: candidate),
                      MenuBarItemActivationGeometry.matches(candidateFrame, target: after) else {
                    trace("hit-test-position-revalidation-failed")
                    return nil
                }
                trace("hit-test-matched-status-item")
                return candidate
            }
            AXUIElementSetMessagingTimeout(node, 0.08)
            var roleValue: CFTypeRef?
            let roleResult = AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &roleValue)
            if roleResult == .success, let role = roleValue as? String,
               MenuBarItemActivationGeometry.isStatusItemRole(role),
               let frame = accessibilityFrame(of: node),
               MenuBarItemActivationGeometry.matches(frame, target: before) {
                candidate = node
            }
            guard depth < 4, let parent = elementAttribute(node, attribute: kAXParentAttribute),
                  !CFEqual(parent, node) else { break }
            node = parent
        }
        trace("hit-test-no-status-item-ancestor")
        return nil
    }

    nonisolated private static func elementAttribute(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            trace(attribute == kAXParentAttribute ? "hit-test-parent-query-failed" : "hit-test-extras-query-failed",
                  error: result)
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    nonisolated private static func currentFrame(windowID: CGWindowID, ownerPID: pid_t,
                                                visibleAreas: [CGRect]? = nil) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let info = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
              (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID,
              (info[kCGWindowLayer as String] as? NSNumber)?.intValue == Int(CGWindowLevelForKey(.statusWindow)),
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              MenuBarItemActivationGeometry.isValid(rect) else { return nil }
        let frame = MenuBarItemActivationGeometry.appKitFrame(rect, mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
        if let visibleAreas {
            let onScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
            guard (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  MenuBarItemActivationGeometry.canHitTest(frame, isOnScreen: onScreen,
                                                          visibleAreas: visibleAreas) else { return nil }
        }
        return frame
    }

    nonisolated private static func children(of element: AXUIElement) -> [AXUIElement]? {
        // Apple's timeout is per AXUIElement instance, not inherited by children.
        AXUIElementSetMessagingTimeout(element, 0.08)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let values = value as? [AnyObject] else {
            trace("children-query-failed", error: result)
            return nil
        }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
    }

    nonisolated private static func accessibilityFrame(of element: AXUIElement) -> CGRect? {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        guard positionResult == .success else {
            trace("position-query-failed", error: positionResult)
            return nil
        }
        let sizeResult = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        guard sizeResult == .success else {
            trace("size-query-failed", error: sizeResult)
            return nil
        }
        guard let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            trace("position-value-type-invalid")
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size) else { return nil }
        let rect = CGRect(origin: point, size: size)
        guard MenuBarItemActivationGeometry.isValid(rect) else { return nil }
        return MenuBarItemActivationGeometry.appKitFrame(rect, mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
    }

    nonisolated private static func trace(_ stage: String, error: AXError? = nil) {
        // Stage names are our own constants. Never log app titles, menu contents,
        // icon images, paths, PIDs, or accessibility attribute values.
        if let error {
            logger.notice("stage=\(stage, privacy: .public) axCode=\(error.rawValue, privacy: .public)")
        } else {
            logger.notice("stage=\(stage, privacy: .public)")
        }
    }
}

enum MenuBarItemActivationGeometry {
    static func isValid(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite
            && frame.width >= 1 && frame.width <= 600 && frame.height >= 1 && frame.height <= 100
    }

    static func appKitFrame(_ topLeftFrame: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: topLeftFrame.minX, y: mainDisplayHeight - topLeftFrame.maxY,
               width: topLeftFrame.width, height: topLeftFrame.height)
    }

    static func quartzCenter(of appKitFrame: CGRect, mainDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: appKitFrame.midX, y: mainDisplayHeight - appKitFrame.midY)
    }

    static func canHitTest(_ frame: CGRect, isOnScreen: Bool, visibleAreas: [CGRect]) -> Bool {
        isValid(frame) && isOnScreen && visibleAreas.contains { area in
            if area.contains(frame) { return true }
            // macOS 26 can report a 33 pt status proxy over a 32 pt auxiliary
            // menu-bar strip. Permit only its one-point lower edge overhang:
            // the top and both horizontal boundaries stay strictly contained.
            return (24...64).contains(area.height) && frame.maxY == area.maxY
                && frame.minX >= area.minX && frame.maxX <= area.maxX
                && frame.minY >= area.minY - 1
        }
    }

    /// AXButton is accepted only after its ancestry is verified against the
    /// application's AXExtrasMenuBar by hitTestItem.
    static func isStatusItemRole(_ role: String) -> Bool {
        role == kAXMenuBarItemRole || role == kAXButtonRole
    }

    /// Tolerates the small accessibility content inset, but never selects the
    /// nearest unrelated item when a matching item has disappeared.
    static func matches(_ candidate: CGRect, target: CGRect) -> Bool {
        isValid(candidate) && isValid(target)
            && abs(candidate.midX - target.midX) <= 2
            && abs(candidate.midY - target.midY) <= 3
            && abs(candidate.width - target.width) <= 4
            && abs(candidate.height - target.height) <= 12
    }

    static func uniquelyMatchingIndex(frames: [CGRect], target: CGRect) -> Int? {
        let matches = frames.indices.filter { self.matches(frames[$0], target: target) }
        return matches.count == 1 ? matches.first : nil
    }

    static func preferredAction(_ actions: [String]) -> String? {
        if actions.contains(kAXPressAction) { return kAXPressAction }
        if actions.contains(kAXShowMenuAction) { return kAXShowMenuAction }
        return nil
    }

    static func actionResult(_ error: AXError) -> MenuBarItemActivationResult {
        switch error {
        case .success: .performed
        case .cannotComplete, .failure:
            .unconfirmed("已请求打开图标，请在原菜单栏中查看；结束操作后恢复收起。")
        default:
            .unavailable("这个图标未能执行打开操作，请在原菜单栏中打开。")
        }
    }

    static func shouldTryShowMenu(after error: AXError, attemptedAction: String,
                                 advertisedActions: [String]) -> Bool {
        error == .actionUnsupported && attemptedAction == kAXPressAction
            && advertisedActions.contains(kAXShowMenuAction)
    }
}
