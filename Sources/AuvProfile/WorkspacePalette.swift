import SwiftUI

enum WorkspacePalette {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let navigation = Color(nsColor: .underPageBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let card = Color.primary.opacity(0.05)
    static let line = Color(nsColor: .separatorColor)
    static let accent = Color.accentColor
    static let selection = Color.accentColor.opacity(0.15)
    static let enabled = Color.accentColor
    static let enabledBackground = Color.accentColor.opacity(0.15)
}
