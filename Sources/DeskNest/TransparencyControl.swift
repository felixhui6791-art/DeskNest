import SwiftUI

/// Changes background transparency while keeping the surface's content fully visible.
struct TransparencyControl: View {
    let title: String
    @Binding var value: Double
    var compact = false

    private var percent: Int { Int((value * 100).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            HStack(spacing: 8) {
                Text(title).fontWeight(.medium)
                Spacer()
                Button("恢复默认") { value = 0 }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("恢复\(title)默认值")
                    .disabled(value == 0)
                Text("\(percent)%")
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
            Slider(value: $value, in: AppearanceSettings.transparencyRange, step: 0.01)
                .accessibilityLabel(title)
                .accessibilityValue("\(percent)%")
            if !compact {
                HStack {
                    Text("默认磨砂玻璃")
                    Spacer()
                    Text("背景更通透")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.font(.system(size: compact ? 10 : 12))
    }
}
