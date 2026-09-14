import Foundation
import Testing
@testable import DeskNest

struct AppUpdateTests {
    private func info(_ channel: DistributionChannel) -> [String: Any] {
        ["DeskNestChannel": channel.rawValue, "CFBundleIdentifier": channel.bundleIdentifier,
         "CFBundleShortVersionString": "0.9.0", "SUFeedURL": channel.feedURL.absoluteString,
         "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()]
    }

    @Test func channelsHaveIndependentIdentitiesAndStorage() {
        #expect(DistributionChannel.release.bundleIdentifier != DistributionChannel.beta.bundleIdentifier)
        #expect(DistributionChannel.release.dataDirectoryName == "DeskNest")
        #expect(DistributionChannel.beta.dataDirectoryName != "DeskNest")
        #expect(DistributionChannel.release.feedURL != DistributionChannel.beta.feedURL)
    }

    @Test(arguments: DistributionChannel.allCases)
    func rejectsCrossChannelOrIncompleteConfigurations(channel: DistributionChannel) {
        let original = info(channel)
        let release = AppRelease.read(original)
        #expect(release.hasValidUpdateConfiguration(original))
        let other: DistributionChannel = channel == .release ? .beta : .release
        for (key, value) in [("SUFeedURL", other.feedURL.absoluteString),
                             ("CFBundleIdentifier", other.bundleIdentifier),
                             ("DeskNestChannel", "unknown"), ("SUPublicEDKey", "invalid")] {
            var changed = original
            changed[key] = value
            #expect(!release.hasValidUpdateConfiguration(changed))
        }
        #expect(!release.hasValidUpdateConfiguration([:]))
    }

    @Test func legacyBuildRemainsReleaseWithoutEnablingUpdates() {
        let old: [String: Any] = ["CFBundleShortVersionString": "0.8.2"]
        let release = AppRelease.read(old)
        #expect(release.channel == .release)
        #expect(release.version == "0.8.2")
        #expect(!release.hasValidUpdateConfiguration(old))
    }
}
