import SwiftUI

enum WorkspacePalette {
    static let background = adaptive(light: 0xFCFDFF, dark: 0x1E2633)
    static let navigation = adaptive(light: 0xF1F4F9, dark: 0x232D3D)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x222C3B)
    static let card = adaptive(light: 0xF4F6FA, dark: 0x283345)
    static let line = adaptive(light: 0xE0E6EE, dark: 0x3E4A5D)
    static let accent = adaptive(light: 0x244FD5, dark: 0x9CB4FF)
    static let selection = adaptive(light: 0xE2EAFB, dark: 0x334365)
    static let enabled = adaptive(light: 0x176347, dark: 0xA6E5CB)
    static let enabledBackground = adaptive(light: 0xE5F4EC, dark: 0x23473F)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
