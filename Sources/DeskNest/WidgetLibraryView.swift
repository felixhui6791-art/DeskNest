import SwiftUI

struct WidgetLibraryView: View {
    @ObservedObject var store: WorkspaceStore
    let add: (WidgetKind) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("桌面，也可以更懂你。").font(.system(size: 29, weight: .semibold))
                    Text("选择小组件，把常用内容和电脑状态放在眼前。")
                        .foregroundStyle(DeskPalette.muted)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 20)], spacing: 20) {
                    card(kind: .systemMonitor, symbol: "memorychip", subtitle: "内存使用 · 硬盘剩余", detail: "每 3 秒更新，随时了解电脑的使用情况。") {
                        SystemMonitorView().padding(22)
                    }
                    card(kind: .files, symbol: "folder", subtitle: "文件 · 文件夹 · 应用", detail: "把常用入口分组放在桌面，原文件留在原处。") {
                        HStack(spacing: 24) {
                            ForEach(["doc.text", "folder.fill", "app.fill"], id: \.self) { symbol in
                                Image(systemName: symbol).font(.system(size: 32, weight: .light))
                            }
                        }.foregroundStyle(WidgetTint.sage.color).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                Label("支持拖动、四周缩放、吸附定位与玻璃配色。", systemImage: "cursorarrow.and.square.on.square.dashed")
                    .font(.system(size: 12)).foregroundStyle(DeskPalette.muted)
            }.padding(30)
        }.scrollIndicators(.hidden)
    }

    private func card<Preview: View>(kind: WidgetKind, symbol: String, subtitle: String,
                                     detail: String, @ViewBuilder preview: () -> Preview) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            preview().frame(height: 220).frame(maxWidth: .infinity)
                .background(WidgetTint.blue.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
            HStack {
                Label(kind.title, systemImage: symbol).font(.system(size: 17, weight: .semibold))
                Spacer()
                Text("\(store.widgets.filter { $0.kind == kind }.count) 个已添加")
                    .font(.system(size: 10)).foregroundStyle(DeskPalette.muted)
            }
            Text(subtitle).font(.system(size: 12, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(DeskPalette.muted).frame(height: 36, alignment: .top)
            Button { add(kind) } label: { Label("添加到桌面", systemImage: "plus") }
                .buttonStyle(DeskPrimaryButtonStyle()).accessibilityLabel("添加\(kind.title)到桌面")
        }.padding(20).background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(DeskPalette.line))
    }
}
