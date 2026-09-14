import AppKit
import SwiftUI

/// Stored independently from the accent color and background transparency.
enum GlassTone: String, Codable, CaseIterable {
    case frost, lightGray, spaceGray, graphite, mistBlue, sage, champagne, rose

    var title: String {
        switch self {
        case .frost: "雾白"
        case .lightGray: "淡灰"
        case .spaceGray: "深空灰"
        case .graphite: "石墨灰"
        case .mistBlue: "雾蓝"
        case .sage: "鼠尾草"
        case .champagne: "香槟"
        case .rose: "烟粉"
        }
    }

    var isDark: Bool { self == .spaceGray || self == .graphite }
    var colorScheme: ColorScheme? { self == .frost ? nil : (isDark ? .dark : .light) }
    var color: Color {
        switch self {
        case .frost: Color(red: 0.93, green: 0.95, blue: 0.97)
        case .lightGray: Color(red: 0.70, green: 0.73, blue: 0.77)
        case .spaceGray: Color(red: 0.25, green: 0.28, blue: 0.33)
        case .graphite: Color(red: 0.15, green: 0.17, blue: 0.20)
        case .mistBlue: Color(red: 0.56, green: 0.68, blue: 0.77)
        case .sage: Color(red: 0.62, green: 0.70, blue: 0.65)
        case .champagne: Color(red: 0.79, green: 0.73, blue: 0.63)
        case .rose: Color(red: 0.76, green: 0.65, blue: 0.67)
        }
    }

    // A retired or malformed optional color must not discard the user's files.
    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(Self.init(rawValue:)) ?? .frost
    }
}

@MainActor
struct GlassTonePicker: View {
    let title: String
    @Binding var selection: GlassTone

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                Text(selection.title).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 28, maximum: 32), spacing: 8)],
                      alignment: .leading, spacing: 8) {
                ForEach(GlassTone.allCases, id: \.self) { tone in
                    Button { selection = tone } label: {
                        Circle().fill(tone.color.gradient)
                            .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1))
                            .overlay {
                                if tone == selection {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(tone.isDark ? .white : .black)
                                }
                            }
                            .frame(width: 24, height: 24).padding(3)
                            .overlay(Circle().strokeBorder(tone == selection ? Color.primary.opacity(0.5) : .clear))
                    }.buttonStyle(.plain)
                        .help(tone.title)
                        .accessibilityLabel("\(title)：\(tone.title)")
                        .accessibilityValue(tone == selection ? "已选择" : "未选择")
                }
            }
        }
    }
}
