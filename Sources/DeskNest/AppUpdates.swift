import AppKit
import Combine
import Sparkle
import SwiftUI

enum DistributionChannel: String, Codable, CaseIterable {
    case release, beta
    var title: String { self == .release ? "发布版" : "测试版" }
    var bundleIdentifier: String { self == .release ? "com.hui.desknest" : "com.hui.desknest.beta" }
    var dataDirectoryName: String { self == .release ? "DeskNest" : "DeskNest-Beta" }
    var applicationName: String { self == .release ? "栖桌" : "栖桌 测试版" }
    var feedURL: URL {
        URL(string: "https://raw.githubusercontent.com/felixhui6791-art/DeskNest/main/updates/\(rawValue).xml")!
    }
}

struct AppRelease {
    let channel: DistributionChannel
    let version: String
    static func read(_ info: [String: Any]) -> Self {
        Self(channel: DistributionChannel(rawValue: info["DeskNestChannel"] as? String ?? "") ?? .release,
             version: info["CFBundleShortVersionString"] as? String ?? "开发中")
    }
    static var current: Self { read(Bundle.main.infoDictionary ?? [:]) }

    func hasValidUpdateConfiguration(_ info: [String: Any]) -> Bool {
        guard info["DeskNestChannel"] as? String == channel.rawValue,
              info["CFBundleIdentifier"] as? String == channel.bundleIdentifier,
              info["SUFeedURL"] as? String == channel.feedURL.absoluteString,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return false }
        return true
    }
}

@MainActor
final class AppUpdateController: NSObject, ObservableObject, @preconcurrency SPUStandardUserDriverDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var configurationError: String?
    @Published private(set) var availableVersion: String?
    @Published var automaticChecks = true {
        didSet {
            guard let controller, controller.updater.automaticallyChecksForUpdates != automaticChecks else { return }
            controller.updater.automaticallyChecksForUpdates = automaticChecks
        }
    }
    private var controller: SPUStandardUpdaterController?
    let release = AppRelease.current

    func start() {
        guard controller == nil else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        guard release.hasValidUpdateConfiguration(info) else {
            configurationError = "当前为未配置更新的开发构建，请使用已打包的应用。"
            return
        }
        let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        controller = updater
        updater.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        updater.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticChecks)
        updater.startUpdater()
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                  forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
    }

    func standardUserDriverWillFinishUpdateSession() { availableVersion = nil }

    func checkForUpdates() {
        guard let controller else {
            let alert = NSAlert()
            alert.messageText = "暂时无法检查更新"
            alert.informativeText = configurationError ?? "更新服务尚未启动。"
            alert.runModal()
            return
        }
        controller.checkForUpdates(nil)
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updates: AppUpdateController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("软件更新").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(updates.release.channel.title).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("当前版本 \(updates.release.version)").font(.system(size: 11)).foregroundStyle(.secondary)
            Toggle("自动检查并提醒更新", isOn: $updates.automaticChecks)
                .disabled(updates.configurationError != nil)
            Text(updates.release.channel == .release
                 ? "只接收发布版更新。发现新版本后会提醒，点击即可下载、安装并重新打开。"
                 : "只接收测试版更新。测试版使用独立设置，不影响发布版的桌面布局。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = updates.configurationError {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let version = updates.availableVersion {
                Text("新版本 \(version) 已可下载").font(.system(size: 12, weight: .medium))
            }
            Button(updates.availableVersion == nil ? "检查更新…" : "查看并安装更新…") {
                updates.checkForUpdates()
            }.disabled(!updates.canCheck)
        }
    }
}
