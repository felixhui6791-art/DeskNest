import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DeskPalette {
    static let canvas = Color(red: 0.967, green: 0.967, blue: 0.952)
    static let sidebar = Color(red: 0.936, green: 0.942, blue: 0.923)
    static let ink = Color(red: 0.16, green: 0.22, blue: 0.18)
    static let muted = Color(red: 0.49, green: 0.53, blue: 0.49)
    static let accent = Color(red: 0.32, green: 0.43, blue: 0.35)
    static let line = Color.black.opacity(0.075)
}

@MainActor
struct ManagerView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var updates: AppUpdateController
    @ObservedObject var menuBarOrganizer: MenuBarOrganizerController
    let arrange: () -> Void
    let showDesktop: () -> Void
    let scanDesktop: () -> Void
    let markReservedArea: () -> Void
    @State private var selectedID: UUID?
    @State private var renameTarget: DesktopWidget?
    @State private var removeTarget: DesktopWidget?
    @State private var showSettings = false
    @State private var showMenuBarPage = false
    @State private var showWidgetLibrary = false

    private var selected: DesktopWidget? { store.widgets.first { $0.id == selectedID } }
    private var fileCount: Int { store.widgets.reduce(0) { $0 + $1.items.count } }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(DeskPalette.line).frame(width: 1)
            VStack(spacing: 0) {
                toolbar
                Rectangle().fill(DeskPalette.line).frame(height: 1)
                if showWidgetLibrary {
                    WidgetLibraryView(store: store) { kind in
                        selectedID = store.addWidget(kind: kind)
                        store.panelsVisible = true
                        showWidgetLibrary = false
                        showMenuBarPage = false
                    }
                } else if showMenuBarPage {
                    MenuBarOrganizerView(store: store, organizer: menuBarOrganizer)
                } else if let widget = selected {
                    detail(widget)
                } else {
                    overview
                }
            }
            .background(DeskPalette.canvas)
        }
        .font(.system(size: 13))
        .foregroundStyle(DeskPalette.ink)
        .tint(DeskPalette.accent)
        .preferredColorScheme(.light)
        .ignoresSafeArea()
        .sheet(item: $renameTarget) { widget in
            RenamePartitionSheet(title: widget.title) { title in
                store.updateTitle(id: widget.id, title: title)
            }
        }
        .alert("移除这个分区？", isPresented: Binding(
            get: { removeTarget != nil },
            set: { if !$0 { removeTarget = nil } }
        )) {
            Button("取消", role: .cancel) { removeTarget = nil }
            Button("移除分区", role: .destructive) {
                if let widget = removeTarget {
                    if selectedID == widget.id { selectedID = nil }
                    store.removeWidget(id: widget.id)
                }
                removeTarget = nil
            }
        } message: {
            Text("将移除“\(removeTarget?.title ?? "")”及其入口，原文件不受影响。")
        }
        .onChange(of: store.widgets.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deskNestShowMenuBarOrganizer)) { _ in
            showWidgetLibrary = false; showMenuBarPage = true
            showSettings = false
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(DeskPalette.accent)
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 19, weight: .medium)).foregroundStyle(.white)
                }.frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("栖桌").font(.system(size: 21, weight: .semibold))
                    Text("D E S K N E S T").font(.system(size: 8, weight: .medium)).foregroundStyle(DeskPalette.muted)
                }
            }
            .padding(.bottom, 34)

            Text("工作空间").font(.system(size: 11, weight: .medium)).foregroundStyle(DeskPalette.muted)
                .padding(.leading, 10).padding(.bottom, 12)
            Button { selectedID = nil; showMenuBarPage = false; showWidgetLibrary = false } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2").frame(width: 18)
                    Text("全部分区").fontWeight(.medium)
                    Spacer()
                    Text("\(store.widgets.count)").font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.white.opacity(0.65), in: Capsule())
                }.padding(.horizontal, 12).padding(.vertical, 11)
                    .background(selectedID == nil && !showMenuBarPage && !showWidgetLibrary ? .white.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).accessibilityIdentifier("allPartitions")

            Button { showWidgetLibrary = false; showMenuBarPage = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "menubar.rectangle").frame(width: 18)
                    Text("菜单栏整理").fontWeight(.medium)
                    Spacer()
                    Circle().fill(store.menuBarOrganizerEnabled ? DeskPalette.accent : DeskPalette.muted.opacity(0.35))
                        .frame(width: 6, height: 6)
                }.padding(.horizontal, 12).padding(.vertical, 12)
                    .background(showMenuBarPage ? .white.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).padding(.top, 5).accessibilityIdentifier("menuBarOrganizer")

            Button { showWidgetLibrary = true; showMenuBarPage = false } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up").frame(width: 18)
                    Text("小组件库").fontWeight(.medium)
                    Spacer()
                }.padding(.horizontal, 12).padding(.vertical, 12)
                    .background(showWidgetLibrary ? .white.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain).padding(.top, 5).accessibilityIdentifier("widgetLibrary")

            HStack {
                Text("我的分区").font(.system(size: 11, weight: .medium)).foregroundStyle(DeskPalette.muted)
                Spacer()
                Button(action: createPartition) { Image(systemName: "plus").font(.system(size: 12)) }
                    .buttonStyle(.plain).help("新建文件分区")
            }.padding(.horizontal, 10).padding(.top, 28).padding(.bottom, 9)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.widgets) { widget in
                        Button { selectedID = widget.id; showMenuBarPage = false; showWidgetLibrary = false } label: {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 3).fill(widget.tint.color).frame(width: 9, height: 9)
                                Text(widget.title).lineLimit(1)
                                Spacer(minLength: 0)
                                if !widget.isVisible { Image(systemName: "eye.slash").font(.system(size: 10)).foregroundStyle(DeskPalette.muted) }
                            }.padding(.horizontal, 12).padding(.vertical, 11)
                                .background(selectedID == widget.id && !showMenuBarPage && !showWidgetLibrary ? .white.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                            .contextMenu { partitionMenu(widget) }
                    }
                }
            }.scrollIndicators(.hidden)

            VStack(alignment: .leading, spacing: 10) {
                Rectangle().fill(DeskPalette.line).frame(height: 1)
                Button { showSettings.toggle() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "slider.horizontal.3")
                        Text("偏好设置")
                        Spacer()
                        Image(systemName: "chevron.up").font(.system(size: 9))
                    }.padding(.vertical, 9).padding(.horizontal, 10)
                }.buttonStyle(.plain)
                    .popover(isPresented: $showSettings, arrowEdge: .trailing) { preferences }
                Button { updates.checkForUpdates() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "arrow.down.circle")
                        Text(updates.availableVersion == nil ? "检查更新" : "发现新版本")
                        Spacer()
                        Text(updates.release.channel.title).font(.system(size: 10)).foregroundStyle(DeskPalette.muted)
                    }.padding(.horizontal, 10)
                }.buttonStyle(.plain).disabled(!updates.canCheck)
                HStack(spacing: 6) {
                    Circle().fill(DeskPalette.accent.opacity(0.65)).frame(width: 5, height: 5)
                    Text("本地保存 · 为自己的桌面而造").font(.system(size: 10)).foregroundStyle(DeskPalette.muted)
                }.padding(.horizontal, 10)
            }
        }
        .padding(.horizontal, 18).padding(.top, 59).padding(.bottom, 22)
        .frame(width: 218)
        .background(DeskPalette.sidebar)
        .alert("需要留意", isPresented: Binding(
            get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } }
        )) {
            Button("知道了") { store.lastError = nil }
        } message: { Text(store.lastError ?? "") }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(showMenuBarPage ? "工作空间" : "我的桌面").foregroundStyle(DeskPalette.muted)
            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(DeskPalette.muted.opacity(0.7))
            Text(showWidgetLibrary ? "小组件库" : showMenuBarPage ? "菜单栏整理" : selected?.title ?? "全部分区").lineLimit(1)
            Spacer(minLength: 10)
            if showMenuBarPage || showWidgetLibrary {
                Button("收起管理窗口", action: showDesktop).buttonStyle(DeskSecondaryButtonStyle())
            } else {
                Button(action: arrange) {
                    Label("整理布局", systemImage: "rectangle.3.group")
                }.buttonStyle(DeskSecondaryButtonStyle()).help("重新排列未锁定的桌面分区")
                Button(action: createPartition) { Label("新建分区", systemImage: "plus") }
                    .buttonStyle(DeskPrimaryButtonStyle()).accessibilityIdentifier("newPartition")
            }
        }.padding(.horizontal, 30).padding(.top, 38).padding(.bottom, 19)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("让常用，触手可及。").font(.system(size: 30, weight: .semibold))
                        Text("把文件、文件夹和应用，放进自己的桌面分区。")
                            .foregroundStyle(DeskPalette.muted)
                    }
                    Spacer()
                    HStack(spacing: 7) {
                        Circle().fill(store.panelsVisible ? DeskPalette.accent : DeskPalette.muted).frame(width: 6, height: 6)
                        Text(store.panelsVisible ? "桌面分区已显示" : "桌面分区已隐藏")
                    }.font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .background(.white.opacity(0.8), in: Capsule())
                }

                HStack(spacing: 26) {
                    metric("\(store.widgets.count)", caption: "个分区")
                    Rectangle().fill(DeskPalette.line).frame(width: 1, height: 23)
                    metric("\(fileCount)", caption: "个文件与应用入口")
                    Spacer()
                    Toggle("显示桌面分区", isOn: $store.panelsVisible).toggleStyle(.switch).controlSize(.small)
                }.padding(.vertical, 4)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 18) {
                    ForEach(store.widgets) { widget in
                        PartitionPreviewCard(widget: widget, store: store,
                            select: { selectedID = widget.id },
                            rename: { renameTarget = widget },
                            remove: { removeTarget = widget }
                        )
                    }
                    Button(action: createPartition) {
                        VStack(spacing: 12) {
                            Image(systemName: "plus").font(.system(size: 22, weight: .light))
                                .frame(width: 48, height: 48)
                                .background(DeskPalette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 15))
                            Text("留一个位置，给新的灵感").font(.system(size: 13, weight: .medium))
                            Text("创建一个属于你的分区").font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
                        }.frame(maxWidth: .infinity).frame(height: 237)
                            .background(DeskPalette.canvas)
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(DeskPalette.accent.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
                            .contentShape(RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(.plain)
                }

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "cursorarrow.and.square.on.square.dashed")
                        .font(.system(size: 21, weight: .light)).foregroundStyle(DeskPalette.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("从一次拖拽开始").font(.system(size: 12, weight: .medium))
                        Text("将 Finder 中的项目拖进分区。双击打开，右键可以在 Finder 中显示。")
                            .font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
                    }
                    Spacer()
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(DeskPalette.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
            }.padding(30)
        }.scrollIndicators(.hidden)
    }

    private func detail(_ widget: DesktopWidget) -> some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 23) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "square.grid.2x2.fill").font(.system(size: 24)).foregroundStyle(widget.tint.color)
                    .frame(width: 54, height: 54).background(widget.tint.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        Text(widget.title).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                        Button { renameTarget = widget } label: { Image(systemName: "pencil").foregroundStyle(DeskPalette.muted) }
                            .buttonStyle(.plain).help("重命名分区")
                    }
                    Text(widget.kind == .systemMonitor ? "实时内存与启动磁盘容量" : "\(widget.items.count) 个入口 · 文件保留在原位置")
                        .font(.system(size: 12)).foregroundStyle(DeskPalette.muted)
                }
                Spacer()
                if widget.kind == .files {
                Menu {
                    Button("添加文件或文件夹…") { chooseFiles(for: widget.id) }
                    Button("添加应用…") { chooseFiles(for: widget.id, applications: true) }
                } label: { Label("添加项目", systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(DeskPalette.line))
                }
            }

            HStack(alignment: .top, spacing: 22) {
                if widget.kind == .systemMonitor {
                    SystemMonitorView(tint: widget.tint.color)
                        .padding(28).frame(minHeight: 300, maxHeight: 347)
                        .background { GlassBackground(transparency: store.partitionTransparency, cornerRadius: 21, tone: widget.glassTone ?? store.partitionGlassTone) }
                        .environment(\.colorScheme, (widget.glassTone ?? store.partitionGlassTone).colorScheme ?? .light)
                        .foregroundStyle((widget.glassTone ?? store.partitionGlassTone).colorScheme == .dark ? Color.white : DeskPalette.ink)
                } else {
                    PartitionContents(widget: widget, store: store, add: { chooseFiles(for: widget.id) })
                }
                VStack(alignment: .leading, spacing: 23) {
                    Text("分区设置").font(.system(size: 13, weight: .semibold))
                    VStack(alignment: .leading, spacing: 12) {
                        Text("点缀色").font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
                        HStack(spacing: 11) {
                            ForEach(WidgetTint.allCases, id: \.self) { tint in
                                Button { store.updateTint(id: widget.id, tint: tint) } label: {
                                    Circle().fill(tint.color).frame(width: 23, height: 23)
                                        .overlay(Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white).opacity(widget.tint == tint ? 1 : 0))
                                        .padding(3).overlay(Circle().stroke(widget.tint == tint ? tint.color.opacity(0.5) : .clear, lineWidth: 1))
                                }.buttonStyle(.plain).help(tint.title).accessibilityLabel(tint.title)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        GlassTonePicker(title: "玻璃颜色", selection: Binding(
                            get: { widget.glassTone ?? store.partitionGlassTone },
                            set: { store.updateGlassTone(id: widget.id, tone: $0) }))
                        Button("跟随统一配色") { store.updateGlassTone(id: widget.id, tone: nil) }
                            .font(.system(size: 10)).disabled(widget.glassTone == nil)
                    }
                    Rectangle().fill(DeskPalette.line).frame(height: 1)
                    Toggle("在桌面显示", isOn: Binding(get: { widget.isVisible }, set: { _ in store.toggleWidgetVisibility(id: widget.id) }))
                        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                    Toggle("显示标题栏", isOn: Binding(
                        get: { widget.showsTitleBar },
                        set: { store.setTitleBarVisible(id: widget.id, visible: $0) }))
                        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                    Toggle("锁定位置", isOn: Binding(get: { widget.isLocked }, set: { _ in store.toggleLock(id: widget.id) }))
                        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                    Text("隐藏标题栏后可拖动顶部留白移动，右键恢复标题栏。拖动边缘调整大小；锁定后保持布局。")
                        .font(.system(size: 11)).foregroundStyle(DeskPalette.muted).lineSpacing(5)
                    Rectangle().fill(DeskPalette.line).frame(height: 1)
                    Button { removeTarget = widget } label: {
                        Label("移除分区", systemImage: "trash").font(.system(size: 12)).foregroundStyle(DeskPalette.muted)
                    }.buttonStyle(.plain)
                }.padding(20).frame(width: 216)
                    .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 16))
            }
            HStack(spacing: 7) {
                Image(systemName: "link")
                Text(widget.kind == .systemMonitor ? "每 3 秒读取本机状态；硬盘剩余不包含可清除空间。" : "这里保存的是文件入口。移除入口不会删除原文件。")
            }.font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
            Spacer(minLength: 0)
        }.padding(30)
        }.scrollIndicators(.hidden)
    }

    private var preferences: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("偏好设置").font(.system(size: 17, weight: .semibold))
            UpdateSettingsView(updates: updates)
            Divider()
            Toggle("显示桌面分区", isOn: $store.panelsVisible)
            Label("固定显示在桌面", systemImage: "desktopcomputer")
                .font(.system(size: 12, weight: .medium))
            Text("分区留在桌面，应用窗口会自然盖住它们。需要固定分区的位置时，开启“锁定位置”。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            GlassTonePicker(title: "统一分区玻璃颜色", selection: $store.partitionGlassTone)
            TransparencyControl(title: "分区背景透明度", value: $store.partitionTransparency)
            GlassTonePicker(title: "折叠面板玻璃颜色", selection: $store.menuBarGlassTone)
            TransparencyControl(title: "折叠面板背景透明度", value: $store.menuBarTransparency)
            Text("分区默认跟随统一配色，也可在各自设置中单独选色。折叠面板独立调整。0% 为默认磨砂玻璃；数值越大，背景越通透，文字和图标保持清晰。设置实时生效、自动保存。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            Toggle("拖动吸附", isOn: $store.snappingEnabled)
            Text("吸附到网格、屏幕边缘和相邻分区。按住 Option 可临时自由摆放。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Toggle("避开原生桌面小组件", isOn: $store.avoidNativeWidgets)
            Text(store.avoidNativeWidgets ? store.desktopScanMessage : "已暂停原生组件避让。手动保留区域仍会生效。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action: scanDesktop) { Label("重新扫描桌面组件", systemImage: "arrow.clockwise") }
                .disabled(!store.avoidNativeWidgets)
            Divider()
            Button(action: {
                showSettings = false
                markReservedArea()
            }) { Label("标记保留区域…", systemImage: "rectangle.dashed") }
            Text("有未识别到的组件？先显示桌面，再标记一块需要避让的位置。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !store.reservedAreas.isEmpty {
                ScrollView {
                    VStack(spacing: 9) {
                        ForEach(store.reservedAreas) { area in
                            HStack {
                                Label(area.title, systemImage: "rectangle.dashed")
                                Spacer()
                                Button {
                                    store.removeReservedArea(id: area.id)
                                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                    .buttonStyle(.plain).help("取消这块区域的保留")
                            }.font(.system(size: 11))
                        }
                    }
                }.frame(maxHeight: 75)
            }
            Divider()
            Button("收起管理窗口", action: showDesktop)
            Text("关闭管理窗口后，栖桌仍在菜单栏运行。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.toggleStyle(.switch).controlSize(.small).padding(23).frame(width: 340)
        }.frame(width: 340, height: 680)
    }

    @ViewBuilder private func partitionMenu(_ widget: DesktopWidget) -> some View {
        Toggle("显示标题栏", isOn: Binding(
            get: { widget.showsTitleBar },
            set: { store.setTitleBarVisible(id: widget.id, visible: $0) }))
        Button("重命名…") { renameTarget = widget }
        Button(widget.isVisible ? "从桌面隐藏" : "在桌面显示") { store.toggleWidgetVisibility(id: widget.id) }
        Button(widget.isLocked ? "解锁位置" : "锁定位置") { store.toggleLock(id: widget.id) }
        Divider()
        Button("移除分区…", role: .destructive) { removeTarget = widget }
    }

    private func metric(_ value: String, caption: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(value).font(.system(size: 25, weight: .medium, design: .rounded))
            Text(caption).font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
        }
    }

    private func createPartition() {
        showMenuBarPage = false
        showWidgetLibrary = false
        selectedID = store.addWidget(kind: .files)
        store.panelsVisible = true
    }

    private func chooseFiles(for id: UUID, applications: Bool = false) {
        ManagerFileActions.choose(store: store, widgetID: id, applications: applications)
    }
}

@MainActor
private struct PartitionPreviewCard: View {
    let widget: DesktopWidget
    @ObservedObject var store: WorkspaceStore
    let select: () -> Void
    let rename: () -> Void
    let remove: () -> Void
    @State private var dropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2.fill").font(.system(size: 13)).foregroundStyle(widget.tint.color)
                Button(action: select) { Text(widget.title).font(.system(size: 14, weight: .semibold)).lineLimit(1) }
                    .buttonStyle(.plain)
                Spacer(minLength: 2)
                Menu {
                    Button("管理分区", action: select)
                    if widget.kind == .files { Button("添加项目…") { ManagerFileActions.choose(store: store, widgetID: widget.id) } }
                    Button("重命名…", action: rename)
                    Button(widget.isVisible ? "从桌面隐藏" : "在桌面显示") { store.toggleWidgetVisibility(id: widget.id) }
                    Divider()
                    Button("移除分区…", role: .destructive, action: remove)
                } label: { Image(systemName: "ellipsis").foregroundStyle(DeskPalette.muted).frame(width: 22, height: 22) }
                    .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
            }.padding(.horizontal, 19).padding(.top, 18).padding(.bottom, 13)

            Group {
                if widget.kind == .systemMonitor {
                    SystemMonitorView(tint: widget.tint.color).padding(.horizontal, 20)
                        .contentShape(Rectangle()).onTapGesture(perform: select)
                } else if widget.items.isEmpty {
                    Button(action: select) {
                        VStack(spacing: 9) {
                            Image(systemName: "tray.and.arrow.down").font(.system(size: 30, weight: .ultraLight))
                                .foregroundStyle(widget.tint.color.opacity(0.7))
                            Text(dropTarget ? "松开，加入这个分区" : "拖入文件，开始收纳")
                                .font(.system(size: 12)).foregroundStyle(DeskPalette.muted)
                            Text("文件 · 文件夹 · 应用").font(.system(size: 10)).foregroundStyle(DeskPalette.muted.opacity(0.75))
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 13) {
                        ForEach(Array(widget.items.prefix(6))) { item in
                            VStack(spacing: 4) {
                                NativeFileIcon(item: item, size: 33)
                                Text(item.name).font(.system(size: 10)).lineLimit(1)
                            }.frame(maxWidth: .infinity).contentShape(Rectangle())
                                .onTapGesture(count: 2) { store.openItem(item) }
                                .help(item.path)
                        }
                    }.padding(.horizontal, 17).frame(maxHeight: .infinity)
                        .onTapGesture(perform: select)
                }
            }.frame(height: 139)

            HStack {
                Text(widget.kind == .systemMonitor ? "实时系统状态" : "\(widget.items.count) 个入口")
                Spacer()
                if widget.isLocked { Image(systemName: "lock.fill").font(.system(size: 9)) }
                Circle().fill(widget.isVisible && store.panelsVisible ? widget.tint.color : DeskPalette.muted.opacity(0.45)).frame(width: 5, height: 5)
                Text(widget.isVisible && store.panelsVisible ? "桌面可见" : "已隐藏")
            }.font(.system(size: 10)).foregroundStyle(DeskPalette.muted)
                .padding(.horizontal, 19).padding(.vertical, 13)
        }
        .background(.white.opacity(0.87), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(dropTarget ? widget.tint.color : DeskPalette.line, lineWidth: dropTarget ? 2 : 1))
        .shadow(color: .black.opacity(0.015), radius: 6, y: 3)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget) { providers in
            ManagerFileActions.accept(providers, store: store, widgetID: widget.id)
        }
    }
}

@MainActor
private struct PartitionContents: View {
    let widget: DesktopWidget
    @ObservedObject var store: WorkspaceStore
    let add: () -> Void
    @State private var dropTarget = false
    @State private var selectedItemID: UUID?

    var body: some View {
        Group {
            if widget.items.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 52, weight: .ultraLight))
                        .foregroundStyle(widget.tint.color.opacity(0.8))
                    Text(dropTarget ? "松开即可添加" : "给常用文件一个位置").font(.system(size: 17, weight: .medium))
                    Text("拖入文件、文件夹或应用\n也可以从 Finder 中选择")
                        .font(.system(size: 12)).foregroundStyle(DeskPalette.muted)
                        .multilineTextAlignment(.center).lineSpacing(6)
                    Button("选择文件…", action: add).buttonStyle(DeskPrimaryButtonStyle()).padding(.top, 3)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 12)], alignment: .leading, spacing: 16) {
                        ForEach(widget.items) { item in
                            VStack(spacing: 8) {
                                NativeFileIcon(item: item, size: 48)
                                Text(item.name).font(.system(size: 11)).lineLimit(2)
                                    .multilineTextAlignment(.center).frame(height: 30, alignment: .top)
                            }.padding(.vertical, 12).frame(maxWidth: .infinity)
                                .background(selectedItemID == item.id ? widget.tint.color.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 11))
                                .contentShape(RoundedRectangle(cornerRadius: 11))
                                .onTapGesture(count: 2) { store.openItem(item) }
                                .onTapGesture { selectedItemID = item.id }
                                .contextMenu {
                                    Button("打开") { store.openItem(item) }
                                    Button("在 Finder 中显示") { store.revealItem(item) }
                                    Divider()
                                    Button("从分区移除", role: .destructive) { store.removeItem(id: item.id, from: widget.id) }
                                }
                                .help(item.path)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(item.name)
                                .accessibilityAction(named: "打开") { store.openItem(item) }
                        }
                    }.padding(18)
                }
            }
        }.frame(maxWidth: .infinity).frame(minHeight: 347, maxHeight: .infinity)
            .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(dropTarget ? widget.tint.color : DeskPalette.line, style: StrokeStyle(lineWidth: dropTarget ? 2 : 1, dash: widget.items.isEmpty ? [5, 5] : [])))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget) { providers in
                ManagerFileActions.accept(providers, store: store, widgetID: widget.id)
            }
    }
}

@MainActor
private struct NativeFileIcon: View {
    let item: DesktopItem
    let size: CGFloat
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: item.resolvedURL?.path ?? item.path))
            .resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
    }
}

struct DeskPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 10)
            .background(DeskPalette.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct DeskSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12))
            .foregroundStyle(DeskPalette.ink).padding(.horizontal, 12).padding(.vertical, 10)
            .background(.white.opacity(configuration.isPressed ? 0.45 : 0.9), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(DeskPalette.line))
    }
}

private struct RenamePartitionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    let save: (String) -> Void
    init(title: String, save: @escaping (String) -> Void) {
        _title = State(initialValue: title)
        self.save = save
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("为分区起个名字").font(.system(size: 19, weight: .semibold))
            TextField("例如：正在做的项目", text: $title).textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: commit).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(27).frame(width: 350)
    }
    private func commit() {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        save(clean)
        dismiss()
    }
}

@MainActor
private enum ManagerFileActions {
    static func choose(store: WorkspaceStore, widgetID: UUID, applications: Bool = false) {
        FileImportCoordinator.present(store: store, widgetID: widgetID, applications: applications)
    }

    static func accept(_ providers: [NSItemProvider], store: WorkspaceStore, widgetID: UUID) -> Bool {
        let supported = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        for provider in supported {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { payload, _ in
                let url: URL?
                if let data = payload as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let value = payload as? URL { url = value }
                else if let value = payload as? String { url = URL(string: value) }
                else { url = nil }
                guard let url, url.isFileURL else { return }
                Task { @MainActor in store.addItems(urls: [url], to: widgetID) }
            }
        }
        return !supported.isEmpty
    }
}
