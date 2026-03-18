/// PMuxTheme — Design tokens for the Termius-style dark UI.
/// Single source of truth for colors, fonts, and spacing.

import SwiftUI
import AppKit

// MARK: - Colors

enum PMuxColors {
    enum BG {
        static let base     = Color(red: 0.075, green: 0.078, blue: 0.122)  // #13141f
        static let raised   = Color(red: 0.102, green: 0.106, blue: 0.180)  // #1a1b2e
        static let surface  = Color(red: 0.145, green: 0.149, blue: 0.251)  // #252640
        static let elevated = Color(red: 0.180, green: 0.184, blue: 0.290)  // #2e2f4a
    }

    static let accent      = Color(red: 0.125, green: 0.569, blue: 0.965)  // #2091f6
    static let accentHover = Color(red: 0.231, green: 0.639, blue: 1.000)  // #3ba3ff

    enum Border {
        static let subtle = Color(red: 0.165, green: 0.169, blue: 0.239)    // #2a2b3d
    }

    enum Text {
        static let primary   = Color(red: 0.910, green: 0.914, blue: 0.929) // #e8e9ed
        static let secondary = Color(red: 0.545, green: 0.553, blue: 0.639) // #8b8da3
        static let tertiary  = Color(red: 0.353, green: 0.361, blue: 0.447) // #5a5c72
        static let accent    = Color(red: 0.125, green: 0.569, blue: 0.965) // #2091f6
    }

    enum Status {
        static let ok        = Color(red: 0.204, green: 0.816, blue: 0.345) // #34d058
        static let degraded  = Color(red: 0.941, green: 0.706, blue: 0.161) // #f0b429
        static let bad       = Color(red: 0.976, green: 0.451, blue: 0.086) // #f97316
        static let lost      = Color(red: 0.973, green: 0.318, blue: 0.286) // #f85149
        static let offline   = Color(red: 0.353, green: 0.361, blue: 0.447) // #5a5c72
    }

    // NSColor equivalents for AppKit contexts
    enum NS {
        static let base = NSColor(red: 0.075, green: 0.078, blue: 0.122, alpha: 1)
    }
}

// MARK: - Fonts

enum PMuxFonts {
    static let heading     = Font.system(size: 14, weight: .semibold)
    static let body        = Font.system(size: 13, weight: .regular)
    static let bodyBold    = Font.system(size: 13, weight: .medium)
    static let caption     = Font.system(size: 11, weight: .regular)
    static let captionBold = Font.system(size: 11, weight: .medium)
    static let metric      = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let metricSmall = Font.system(size: 10, weight: .regular, design: .monospaced)
    static let pill        = Font.system(size: 10, weight: .semibold, design: .monospaced)
    static let tabActive   = Font.system(size: 12, weight: .medium)
    static let tabInactive = Font.system(size: 12, weight: .regular)
}

// MARK: - Spacing

enum PMuxSpacing {
    static let sidebarWidth: CGFloat = 240
    static let statusBarHeight: CGFloat = 28
    static let tabBarHeight: CGFloat = 38
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 8
    static let gridGap: CGFloat = 4
    static let modalRadius: CGFloat = 12
    static let statusDotLarge: CGFloat = 10
    static let statusDotSmall: CGFloat = 6
    static let pillRadius: CGFloat = 4
}
