import CoreGraphics

/// AppKit screen coordinates: preserve the top edge beneath the status item as
/// the tray changes size, while keeping every edge within the anchor's display.
enum FoldedMenuBarTrayPlacement {
    static func frame(contentSize: CGSize, anchor: CGRect, visibleFrame: CGRect) -> CGRect {
        let margin: CGFloat = 8
        let gap: CGFloat = 6
        let usable = visibleFrame.insetBy(dx: margin, dy: margin)
        let top = max(usable.minY + 1, min(anchor.minY - gap, usable.maxY))
        let width = min(contentSize.width, max(1, usable.width))
        let height = min(contentSize.height, max(1, top - usable.minY))
        let x = min(max(anchor.midX - width / 2, usable.minX), usable.maxX - width)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}
