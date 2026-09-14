import Foundation
import Testing
@testable import DeskNest

struct SystemMonitorTests {
    @Test func memoryExcludesPurgeableAndIncludesCompressed() throws {
        let reading = try #require(CapacityReading.memory(total: 16_000, pageSize: 100,
            internalPages: 40, purgeablePages: 10, wiredPages: 20, compressedPages: 5))
        #expect(reading.used == 5_500)
        #expect(reading.remaining == 10_500)
    }

    @Test func capacityClampsInvalidCountersWithoutUnderflow() throws {
        let reading = try #require(CapacityReading.memory(total: 100, pageSize: 100,
            internalPages: 2, purgeablePages: 9, wiredPages: 1, compressedPages: 1))
        #expect(reading.used == 100)
        #expect(reading.fraction == 1)
        #expect(CapacityReading(total: 0, used: 5) == nil)
        #expect(CapacityReading.memory(total: 100, pageSize: 0, internalPages: 2,
            purgeablePages: 0, wiredPages: 1, compressedPages: 1) == nil)
        let huge = try #require(CapacityReading.memory(total: UInt64.max, pageSize: UInt64.max,
            internalPages: UInt64.max, purgeablePages: 0, wiredPages: UInt64.max, compressedPages: UInt64.max))
        #expect(huge.used == UInt64.max)
    }

    @Test @MainActor func monitorPersistsAlongsideFilePartitions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(directory: directory)
        let original = store.widgets
        let id = store.addWidget(kind: .systemMonitor)
        store.updateGlassTone(id: id, tone: .spaceGray)
        store.toggleLock(id: id)
        let restored = WorkspaceStore(directory: directory)
        #expect(Array(restored.widgets.prefix(original.count)) == original)
        let monitor = try #require(restored.widgets.first { $0.id == id })
        #expect(monitor.kind == .systemMonitor)
        #expect(monitor.isLocked)
        #expect(monitor.glassTone == .spaceGray)
        let file = directory.appendingPathComponent("example.txt")
        try Data("retain".utf8).write(to: file)
        restored.addItems(urls: [file], to: id)
        #expect(restored.widgets.first { $0.id == id }?.items.isEmpty == true)
        restored.removeWidget(id: id)
        #expect(WorkspaceStore(directory: directory).widgets == original)
        #expect(try String(contentsOf: file, encoding: .utf8) == "retain")
    }

    @Test func liveSystemSampleIsBoundedAndShared() async throws {
        let reader = SystemStatsReader()
        let first = await reader.sample()
        let memory = try #require(first.memory)
        let disk = try #require(first.disk)
        #expect(memory.total == ProcessInfo.processInfo.physicalMemory)
        #expect(memory.used <= memory.total)
        #expect(disk.total > 0)
        #expect(disk.remaining <= disk.total)
        let next = await reader.sample()
        #expect(next.sampledAt == first.sampledAt)
    }
}
