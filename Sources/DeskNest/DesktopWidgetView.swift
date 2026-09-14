import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct DesktopWidgetView: View {
    @ObservedObject var store: WorkspaceStore
    let widgetID: UUID
    var openManager: () -> Void

    @Environment(\.colorScheme) private var systemColorScheme
    @State private var dropTargeted = false
    @State private var selectedItemID: UUID?
    @State private var renaming = false
    @State private var proposedTitle = ""

    private var widget: DesktopWidget? {
        store.widgets.first { $0.id == widgetID }
    }

    var body: some View {
        Group {
            if let widget {
                card(widget)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("给分区起个名字", isPresented: $renaming) {
            TextField("分区名称", text: $proposedTitle)
            Button("取消", role: .cancel) {}
            Button("保存") {
                store.updateTitle(id: widgetID, title: proposedTitle)
            }
        }
    }

    private func card(_ widget: DesktopWidget) -> some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 240
            let short = geometry.size.height < 280

            VStack(spacing: 0) {
                if widget.showsTitleBar {
                    header(widget, compact: compact)
                    Rectangle()
                        .fill(widget.tint.color.opacity(0.17))
                        .frame(height: 1)
                        .padding(.horizontal, compact ? 10 : 18)
                } else {
                    PanelDragHandle(isEnabled: !widget.isLocked)
                        .frame(height: 16)
                        .help(widget.isLocked ? "位置已锁定；右键可恢复标题栏" : "拖动顶部留白移动；右键可恢复标题栏")
                        .accessibilityLabel("小组件移动区域")
                }

                if widget.kind == .systemMonitor {
                    if store.panelsVisible && widget.isVisible {
                        SystemMonitorView(tint: widget.tint.color)
                            .padding(.horizontal, compact ? 10 : 20)
                            .padding(.vertical, short ? 4 : 12)
                    } else { Spacer(minLength: 0) }
                } else if widget.items.isEmpty {
                    emptyState(widget, compact: compact || short)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 110), spacing: 10)], spacing: 12) {
                            ForEach(widget.items) { item in
                                itemCell(item, tint: widget.tint.color)
                            }
                        }
                        .padding(.horizontal, compact ? 10 : 16)
                        .padding(.vertical, short ? 6 : 16)
                    }
                    .scrollIndicators(.hidden)
                    .frame(minHeight: 0, maxHeight: .infinity)
                }

                HStack(spacing: 5) {
                    Image(systemName: widget.isLocked ? "lock.fill" : "cursorarrow.and.square.on.square.dashed")
                        .font(.system(size: 9))
                    Text(footerText(widget, compact: compact || short))
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(footerText(widget, compact: false))
                    Spacer(minLength: 0)
                    if !widget.isLocked {
                        ZStack {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 10))
                                .rotationEffect(.degrees(-45))
                                .allowsHitTesting(false)
                            PanelResizeHandle()
                        }
                        .frame(width: 18, height: 14)
                        .help("拖动调整大小，松开吸附；按住 Option 临时自由调整")
                        .accessibilityLabel("调整分区大小")
                    }
                }
                .foregroundStyle(.secondary.opacity(0.8))
                .padding(.horizontal, compact ? 11 : 19)
                .padding(.bottom, short ? 7 : 13)
                .padding(.top, 5)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background {
            GlassBackground(transparency: store.partitionTransparency,
                            cornerRadius: 21, tone: widget.glassTone ?? store.partitionGlassTone)
        }
        .environment(\.colorScheme, (widget.glassTone ?? store.partitionGlassTone).colorScheme ?? systemColorScheme)
        .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .strokeBorder(widget.tint.color, lineWidth: 2.5)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if dropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 21)
                        .fill(widget.tint.color.opacity(0.12))
                    Label("松开，添加到「\(widget.title)」", systemImage: "plus.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(.regularMaterial, in: Capsule())
                }
                .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            acceptFileDrop(providers)
        }
        .contextMenu { widgetMenu(widget) }
        .animation(.easeInOut(duration: 0.16), value: dropTargeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("桌面分区，\(widget.title)")
    }

    private func header(_ widget: DesktopWidget, compact: Bool) -> some View {
        ZStack {
            PanelDragHandle(isEnabled: !widget.isLocked)
                .help("\(widget.title)\n" + (widget.isLocked ? "位置已锁定" : "拖动分区，松开吸附；按住 Option 临时自由放置"))
            HStack(spacing: compact ? 5 : 9) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(widget.tint.color)
                    .frame(width: compact ? 4 : 7, height: compact ? 16 : 19)
                    .allowsHitTesting(false)
                Text(widget.title)
                    .font(.system(size: compact ? 13 : 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .help(widget.title)
                    .allowsHitTesting(false)
                if !compact && widget.kind == .files {
                    Text("\(widget.items.count)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.primary.opacity(0.055), in: Capsule())
                        .allowsHitTesting(false)
                }
                if widget.kind == .files {
                Button {
                    chooseFiles()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: compact ? 22 : 25, height: 25)
                        .background(.primary.opacity(0.045), in: Circle())
                }
                .buttonStyle(.plain)
                .help("添加文件、文件夹或应用")
                .accessibilityLabel("添加文件")
                }

                Menu {
                    widgetMenu(widget)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: compact ? 20 : 22, height: 25)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("分区设置")
                .accessibilityLabel("分区设置")
            }
            .padding(.horizontal, compact ? 10 : 18)
        }
        .frame(height: compact ? 44 : 57)
    }

    private func emptyState(_ widget: DesktopWidget, compact: Bool) -> some View {
        Group {
            if compact {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(widget.tint.color)
                        .accessibilityHidden(true)
                    chooseFilesButton(tint: widget.tint.color)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .help("拖入文件、文件夹或应用，原文件保留在原来的位置")
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(widget.tint.color)
                        .padding(.bottom, 3)
                    Text("把常用文件放在这里")
                        .font(.system(size: 13, weight: .medium))
                    Text("拖入文件、文件夹或应用\n原文件保留在原来的位置")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .foregroundStyle(.secondary)
                    chooseFilesButton(tint: widget.tint.color)
                        .padding(.top, 3)
                }
                .padding(15)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private func chooseFilesButton(tint: Color) -> some View {
        Button("选择文件") { chooseFiles() }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(tint.opacity(0.1), in: Capsule())
    }

    private func footerText(_ widget: DesktopWidget, compact: Bool) -> String {
        if widget.kind == .systemMonitor { return widget.isLocked ? "位置已锁定" : "拖动顶部调整位置" }
        if compact { return widget.isLocked ? "已锁定" : "双击打开" }
        return widget.isLocked ? "位置已锁定 · 仍可添加文件" : "双击打开 · 拖入文件添加"
    }

    private func itemCell(_ item: DesktopItem, tint: Color) -> some View {
        let url = item.resolvedURL ?? URL(fileURLWithPath: item.path)
        return VStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 39, height: 39)
            Text(item.name)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(height: 29, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .padding(.vertical, 7)
        .background(selectedItemID == item.id ? tint.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(count: 2) { store.openItem(item) }
        .onTapGesture { selectedItemID = item.id }
        .help("\(item.name)\n\(url.path)\n双击打开")
        .accessibilityLabel(item.name)
        .accessibilityHint("双击打开")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.openItem(item) }
        .contextMenu {
            Button("打开") { store.openItem(item) }
            Button("在 Finder 中显示") { store.revealItem(item) }
            Divider()
            Button("从分区移除", role: .destructive) {
                store.removeItem(id: item.id, from: widgetID)
            }
        }
    }

    @ViewBuilder
    private func widgetMenu(_ widget: DesktopWidget) -> some View {
        Toggle("显示标题栏", isOn: Binding(
            get: { widget.showsTitleBar },
            set: { store.setTitleBarVisible(id: widgetID, visible: $0) }))
        Divider()
        if widget.kind == .files {
            Button("添加文件…", systemImage: "plus") { chooseFiles() }
        }
        Button("重新命名…", systemImage: "pencil") {
            proposedTitle = widget.title
            renaming = true
        }
        Menu("玻璃颜色", systemImage: "paintpalette") {
            Button("跟随统一配色") { store.updateGlassTone(id: widgetID, tone: nil) }
            Divider()
            ForEach(GlassTone.allCases, id: \.self) { tone in
                Button { store.updateGlassTone(id: widgetID, tone: tone) } label: {
                    Label(tone.title, systemImage: widget.glassTone == tone ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        Menu("点缀色", systemImage: "circle.lefthalf.filled") {
            ForEach([WidgetTint.sage, .clay, .blue, .lavender], id: \.self) { tint in
                Button {
                    store.updateTint(id: widgetID, tint: tint)
                } label: {
                    Label(tint.title, systemImage: widget.tint == tint ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        }
        Divider()
        Button(widget.isLocked ? "解锁位置" : "锁定位置", systemImage: widget.isLocked ? "lock.open" : "lock") {
            store.toggleLock(id: widgetID)
        }
        Button("隐藏这个分区", systemImage: "eye.slash") {
            store.toggleWidgetVisibility(id: widgetID)
        }
        Button("管理所有分区…", systemImage: "rectangle.grid.2x2") { openManager() }
    }

    private func chooseFiles() {
        FileImportCoordinator.present(store: store, widgetID: widgetID)
    }

    private func acceptFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard widget?.kind == .files else { return false }
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        let target = widgetID
        let destinationStore = store
        for provider in matching {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                    Task { @MainActor in
                        destinationStore.lastError = error?.localizedDescription ?? "未能读取拖入的文件，请尝试使用添加按钮。"
                    }
                    return
                }
                Task { @MainActor in
                    destinationStore.addItems(urls: [url], to: target)
                }
            }
        }
        return !matching.isEmpty
    }
}

@MainActor
private struct PanelDragHandle: NSViewRepresentable {
    var isEnabled: Bool

    func makeNSView(context: Context) -> PanelDragView { PanelDragView() }

    func updateNSView(_ nsView: PanelDragView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

@MainActor
private final class PanelDragView: NSView {
    var isEnabled = true
    private var isTracking = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let handler = window as? DesktopPanelInteractionHandling else { return }
        isTracking = handler.beginInteraction(.move, at: NSEvent.mouseLocation)
        if isTracking { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTracking else { return }
        (window as? DesktopPanelInteractionHandling)?.updateInteraction(at: NSEvent.mouseLocation, modifiers: event.modifierFlags)
    }

    override func mouseUp(with event: NSEvent) {
        guard isTracking else { return }
        isTracking = false
        (window as? DesktopPanelInteractionHandling)?.endInteraction(at: NSEvent.mouseLocation, modifiers: event.modifierFlags)
        (isEnabled ? NSCursor.openHand : NSCursor.arrow).set()
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .openHand) }
    }
}

@MainActor
private struct PanelResizeHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> PanelResizeView { PanelResizeView() }
    func updateNSView(_ nsView: PanelResizeView, context: Context) {}
}

@MainActor
private final class PanelResizeView: NSView {
    private var isTracking = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let handler = window as? DesktopPanelInteractionHandling else { return }
        isTracking = handler.beginInteraction(.resize(.bottomRight), at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTracking else { return }
        (window as? DesktopPanelInteractionHandling)?.updateInteraction(at: NSEvent.mouseLocation, modifiers: event.modifierFlags)
    }

    override func mouseUp(with event: NSEvent) {
        guard isTracking else { return }
        isTracking = false
        (window as? DesktopPanelInteractionHandling)?.endInteraction(at: NSEvent.mouseLocation, modifiers: event.modifierFlags)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: PanelResizeCursors.cursor(for: .bottomRight))
    }
}

enum PanelInteractionKind {
    case move
    case resize(PanelResizeDirection)
}

/// Both AppKit handles share the same placement lifecycle, including one final save.
@MainActor
protocol DesktopPanelInteractionHandling: AnyObject {
    func beginInteraction(_ kind: PanelInteractionKind, at location: CGPoint) -> Bool
    func updateInteraction(at location: CGPoint, modifiers: NSEvent.ModifierFlags)
    func endInteraction(at location: CGPoint, modifiers: NSEvent.ModifierFlags)
}
