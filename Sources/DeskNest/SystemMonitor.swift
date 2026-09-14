import Darwin
import Foundation
import SwiftUI

struct CapacityReading: Sendable {
    let total: UInt64
    let used: UInt64
    var remaining: UInt64 { total - used }
    var fraction: Double { Double(used) / Double(total) }

    init?(total: UInt64, used: UInt64) {
        guard total > 0 else { return nil }
        self.total = total
        self.used = min(used, total)
    }

    static func memory(total: UInt64, pageSize: UInt64, internalPages: UInt64,
                       purgeablePages: UInt64, wiredPages: UInt64, compressedPages: UInt64) -> Self? {
        let appPages = internalPages - min(internalPages, purgeablePages)
        let pages = Double(appPages) + Double(wiredPages) + Double(compressedPages)
        let bytes = min(Double(total), pages * Double(pageSize))
        guard total > 0, pageSize > 0, bytes.isFinite else { return nil }
        // Clamp in floating point before conversion; avoid UInt64.max rounding up.
        return Self(total: total, used: bytes >= Double(total) ? total : UInt64(bytes))
    }
}

struct SystemSnapshot: Sendable {
    var memory: CapacityReading?
    var disk: CapacityReading?
    var diskName = "启动磁盘"
    var sampledAt = Date()
}

/// One off-main-thread sample serves all desktop and console previews.
actor SystemStatsReader {
    static let shared = SystemStatsReader()
    private var cached: SystemSnapshot?
    private var lastSample: ContinuousClock.Instant?

    func sample() -> SystemSnapshot {
        let now = ContinuousClock.now
        if let cached, let lastSample, lastSample.duration(to: now) < .seconds(2) { return cached }
        var snapshot = SystemSnapshot()
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        if result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS {
            snapshot.memory = CapacityReading.memory(total: ProcessInfo.processInfo.physicalMemory,
                pageSize: UInt64(pageSize), internalPages: UInt64(stats.internal_page_count),
                purgeablePages: UInt64(stats.purgeable_count), wiredPages: UInt64(stats.wire_count),
                compressedPages: UInt64(stats.compressor_page_count))
        }
        // Use the writable startup data volume, excluding purgeable estimates.
        let volume = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        if let values = try? volume.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey]),
           let total = values.volumeTotalCapacity, total > 0,
           let free = values.volumeAvailableCapacity, free >= 0 {
            snapshot.disk = CapacityReading(total: UInt64(total), used: UInt64(total - min(total, free)))
            snapshot.diskName = values.volumeName ?? "启动磁盘"
        }
        cached = snapshot
        lastSample = now
        return snapshot
    }
}

struct SystemMonitorView: View {
    var tint: Color = WidgetTint.blue.color
    @State private var snapshot: SystemSnapshot?

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 150 || geometry.size.width < 230
            VStack(alignment: .leading, spacing: compact ? 8 : 20) {
                if geometry.size.height < 100 {
                    HStack(spacing: 10) {
                        metric(title: "内存", symbol: "memorychip", reading: snapshot?.memory,
                               showRemaining: false, compact: true)
                        metric(title: "硬盘剩余", symbol: "internaldrive", reading: snapshot?.disk,
                               showRemaining: true, compact: true)
                    }
                } else {
                    metric(title: "内存使用", symbol: "memorychip", reading: snapshot?.memory,
                           showRemaining: false, compact: compact)
                    metric(title: "硬盘剩余", symbol: "internaldrive", reading: snapshot?.disk,
                           showRemaining: true, compact: compact)
                }
                if !compact {
                    HStack(spacing: 5) {
                        Circle().fill(snapshot == nil ? Color.secondary : tint).frame(width: 5, height: 5)
                        Text(snapshot == nil ? "正在读取…" : "每 3 秒更新 · 启动磁盘")
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .task {
            while !Task.isCancelled {
                let next = await SystemStatsReader.shared.sample()
                guard !Task.isCancelled else { return }
                snapshot = next
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func metric(title: String, symbol: String, reading: CapacityReading?,
                        showRemaining: Bool, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: compact ? 10 : 12, weight: .medium))
                Spacer(minLength: 3)
                if let reading {
                    Text("\(Int((showRemaining ? 1 - reading.fraction : reading.fraction) * 100))%")
                        .font(.system(size: compact ? 10 : 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(reading.map { bytes(showRemaining ? $0.remaining : $0.used, disk: showRemaining) } ?? "—")
                    .font(.system(size: compact ? 17 : 27, weight: .medium, design: .rounded))
                if let reading {
                    Text("/ \(bytes(reading.total, disk: showRemaining))").font(.system(size: compact ? 10 : 12)).foregroundStyle(.secondary)
                } else {
                    Text(snapshot == nil ? "读取中" : "暂不可用").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.lineLimit(1).minimumScaleFactor(0.65).monospacedDigit()
            if !compact {
                GeometryReader { bar in
                    Capsule().fill(tint.opacity(0.14))
                    Capsule().fill(tint).frame(width: bar.size.width * (reading.map { showRemaining ? 1 - $0.fraction : $0.fraction } ?? 0))
                }.frame(height: 5)
            }
        }
        .accessibilityElement(children: .combine)
        .help(showRemaining
              ? "\(snapshot?.diskName ?? "启动磁盘")的实际剩余空间，不包含可清除空间。"
              : "物理内存使用估算：应用驻留内存（扣除可清除页）＋联动内存＋压缩内存；不包含文件缓存。")
    }

    private func bytes(_ value: UInt64, disk: Bool) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: disk ? .file : .memory)
    }
}
