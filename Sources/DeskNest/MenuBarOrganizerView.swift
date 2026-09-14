import SwiftUI

extension Notification.Name {
    static let deskNestShowMenuBarOrganizer = Notification.Name("DeskNest.showMenuBarOrganizer")
}

@MainActor
struct MenuBarOrganizerView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var organizer: MenuBarOrganizerController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("把菜单栏，留给常用。").font(.system(size: 28, weight: .semibold))
                        Text("不常用的图标收起来，在菜单栏下方随时取用。")
                            .foregroundStyle(DeskPalette.muted)
                    }
                    Spacer()
                    Label(stateTitle, systemImage: organizer.isTrayShown ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.white.opacity(0.85), in: Capsule())
                }

                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("两组图标，一个开关").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Text("布局示意").font(.system(size: 10)).foregroundStyle(DeskPalette.muted)
                    }
                    HStack(spacing: 16) {
                        HStack(spacing: 13) {
                            sampleIcon("cloud")
                            sampleIcon("headphones")
                            sampleIcon("externaldrive")
                        }.opacity(organizer.isExpanded || !organizer.isEnabled ? 1 : 0.20)
                        Rectangle().fill(DeskPalette.accent.opacity(0.65)).frame(width: 2, height: 27)
                        Image(systemName: organizer.isTrayShown ? "chevron.up" : "chevron.down")
                            .font(.system(size: 15, weight: .semibold)).frame(width: 25)
                        HStack(spacing: 13) {
                            sampleIcon("square.grid.2x2")
                            sampleIcon("wifi")
                            sampleIcon("battery.100percent")
                        }
                        Spacer(minLength: 0)
                        Text("周四  10:24").font(.system(size: 12, weight: .medium)).fixedSize()
                    }.padding(20)
                        .background(DeskPalette.sidebar.opacity(0.8), in: RoundedRectangle(cornerRadius: 13))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("布局示意：分界线左侧为折叠区，箭头右侧为常驻区")
                    HStack {
                        Label("左侧 · 折叠区", systemImage: "tray").frame(maxWidth: .infinity, alignment: .leading)
                        Label("右侧 · 常驻区", systemImage: "pin").frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
                    HStack(spacing: 15) {
                        Image(systemName: "arrow.down").foregroundStyle(DeskPalette.muted)
                        HStack(spacing: 16) {
                            sampleIcon("cloud")
                            sampleIcon("headphones")
                            sampleIcon("externaldrive")
                        }.padding(.horizontal, 18).padding(.vertical, 10)
                            .background(DeskPalette.sidebar.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                        Text("在下方显示折叠区").font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
                        Spacer()
                    }.accessibilityElement(children: .ignore).accessibilityLabel("折叠区图标在菜单栏下方的独立面板显示")
                    Divider()
                    instruction("1", title: "安排图标", detail: "点击“调整图标位置”后保持展开；整理完点 ✓ 或“完成调整并收起”。")
                    instruction("2", title: "按住 ⌘ 拖动", detail: "把不常用的图标拖到竖线左侧；常用图标留在箭头右侧。")
                    instruction("3", title: "在下方取用", detail: "点击箭头，折叠区会显示在下方面板；点选图标打开原菜单。")
                }.padding(23).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 17))

                VStack(alignment: .leading, spacing: 17) {
                    Toggle("启用菜单栏整理", isOn: $store.menuBarOrganizerEnabled)
                        .toggleStyle(.switch).accessibilityIdentifier("enableMenuBarOrganizer")
                    Divider()
                    GlassTonePicker(title: "折叠面板玻璃颜色", selection: $store.menuBarGlassTone)
                    TransparencyControl(title: "折叠面板背景透明度", value: $store.menuBarTransparency)
                    Text("0% 为默认磨砂玻璃；数值越大，背景越通透，文字和图标保持清晰。颜色与透明度统一在控制台调整，设置实时生效、自动保存。")
                        .font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("展开后自动收起").fontWeight(.medium)
                            Text("鼠标停留时暂缓；调整模式需手动完成。")
                                .font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
                        }
                        Spacer()
                        Picker("展开后自动收起", selection: $store.menuBarAutoCollapseDelay) {
                            Text("不自动收起").tag(0)
                            Text("5 秒").tag(5)
                            Text("15 秒").tag(15)
                            Text("30 秒").tag(30)
                        }.labelsHidden().frame(width: 150)
                            .disabled(!store.menuBarOrganizerEnabled)
                    }
                    HStack(spacing: 12) {
                        Button("在下方显示折叠区") { organizer.showFoldedItems() }
                        Button("调整图标位置") { organizer.expand() }
                        Button(organizer.isAdjusting ? "完成调整并收起" : "收起图标") { organizer.collapse() }
                        Spacer()
                    }.disabled(!store.menuBarOrganizerEnabled)
                    Text(organizer.statusMessage).font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(23).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 17))

                Label {
                    Text("面板显示实际折叠区。原始图标预览与菜单操作分别需要屏幕录制、辅助功能权限；授权入口在面板内。点选时会临时展开原菜单栏，部分应用可能不支持辅助功能操作。")
                        .lineSpacing(4)
                } icon: { Image(systemName: "info.circle") }
                    .font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
            }.padding(30)
        }
    }

    private var stateTitle: String {
        !organizer.isEnabled ? "未启用" : organizer.isAdjusting ? "调整模式" : organizer.isTrayShown ? "面板已展开" : organizer.isExpanded ? "原栏已展开" : "已折叠"
    }

    private func sampleIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 27, height: 27)
    }

    private func instruction(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24).background(DeskPalette.sidebar, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(DeskPalette.muted)
            }
        }
    }
}
