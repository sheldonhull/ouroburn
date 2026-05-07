import AppKit

/// Night Owl-derived palette. Background sits a touch darker than the editor original to
/// give the menu bar popover more contrast against the wallpaper. Accents stay close to the
/// canonical Night Owl ramp: cobalt-blue, sea-mint, peach, lime. No pinks.
enum Theme {
    static let background = NSColor(calibratedRed: 0.004, green: 0.086, blue: 0.153, alpha: 1.0) // #011627
    static let backgroundDeep = NSColor(calibratedRed: 0.000, green: 0.063, blue: 0.110, alpha: 1.0) // #00101C
    static let surface = NSColor(calibratedRed: 0.043, green: 0.118, blue: 0.196, alpha: 1.0) // #0B1E32
    static let surfaceMuted = NSColor(calibratedRed: 0.078, green: 0.165, blue: 0.247, alpha: 1.0) // #142A3F
    static let divider = NSColor(calibratedRed: 0.18, green: 0.30, blue: 0.42, alpha: 0.55)

    static let textPrimary = NSColor(calibratedRed: 0.839, green: 0.871, blue: 0.922, alpha: 1.0) // #D6DEEB
    static let textSecondary = NSColor(calibratedRed: 0.580, green: 0.659, blue: 0.722, alpha: 1.0) // #94A8B8
    static let textTertiary = NSColor(calibratedRed: 0.388, green: 0.467, blue: 0.529, alpha: 1.0) // #637787

    /// Night Owl signature blue (`#82AAFF`).
    static let accentBlue = NSColor(calibratedRed: 0.510, green: 0.667, blue: 1.000, alpha: 1.0)
    /// Night Owl mint (`#7FDBCA`).
    static let accentMint = NSColor(calibratedRed: 0.498, green: 0.859, blue: 0.792, alpha: 1.0)
    /// Night Owl peach (`#ECC48D`).
    static let accentPeach = NSColor(calibratedRed: 0.925, green: 0.769, blue: 0.553, alpha: 1.0)
    /// Night Owl lime (`#ADDB67`).
    static let accentLime = NSColor(calibratedRed: 0.678, green: 0.859, blue: 0.404, alpha: 1.0)
    /// Night Owl red (`#EF5350`) reserved for spike state and hot sustained burns.
    static let accentRed = NSColor(calibratedRed: 0.937, green: 0.325, blue: 0.314, alpha: 1.0)

    static func titleFont(size: CGFloat = 13) -> NSFont {
        if let descriptor = NSFont.systemFont(ofSize: size, weight: .semibold)
            .fontDescriptor.withDesign(.rounded) {
            return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size, weight: .semibold)
        }
        return NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    static func bodyFont(size: CGFloat = 11) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .regular)
    }

    static func numericFont(size: CGFloat = 11) -> NSFont {
        // Tabular figures keep columns aligned without using a monospace face.
        let descriptor = NSFont.systemFont(ofSize: size, weight: .medium)
            .fontDescriptor.addingAttributes([
                .featureSettings: [[
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
                ]],
            ])
        return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size, weight: .medium)
    }

    /// Soft glow used on titles. Cyan halo, low alpha — present without screaming.
    static func glow(color: NSColor = accentBlue, radius: CGFloat = 6) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = radius
        shadow.shadowOffset = .zero
        return shadow
    }

    static func glowAttributedTitle(_ text: String, color: NSColor = accentBlue, font: NSFont? = nil) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font ?? titleFont(size: 13),
            .foregroundColor: color,
            .shadow: glow(color: color, radius: 5),
        ])
    }
}
