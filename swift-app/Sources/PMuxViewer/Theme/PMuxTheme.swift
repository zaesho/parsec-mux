/// PMuxTheme — Slate/graphite design tokens.
/// Single source of truth for colors, fonts, and spacing.

import SwiftUI
import AppKit

// MARK: - Colors

enum PMuxColors {
    enum BG {
        static let base     = Color(red: 0.098, green: 0.106, blue: 0.118)  // #191b1e
        static let raised   = Color(red: 0.129, green: 0.137, blue: 0.153)  // #212327
        static let surface  = Color(red: 0.161, green: 0.173, blue: 0.192)  // #292c31
        static let elevated = Color(red: 0.200, green: 0.212, blue: 0.235)  // #33363c
    }

    static let accent      = Color(red: 0.337, green: 0.588, blue: 0.976)  // #5696f9
    static let accentHover = Color(red: 0.459, green: 0.678, blue: 1.000)  // #75adff
    static let accentMuted = Color(red: 0.337, green: 0.588, blue: 0.976).opacity(0.15)

    enum Border {
        static let subtle  = Color(red: 0.220, green: 0.231, blue: 0.255)   // #383b41
        static let strong  = Color(red: 0.280, green: 0.294, blue: 0.325)   // #474b53
    }

    enum Text {
        static let primary   = Color(red: 0.922, green: 0.933, blue: 0.953) // #ebeeF3
        static let secondary = Color(red: 0.580, green: 0.612, blue: 0.663) // #949ca9
        static let tertiary  = Color(red: 0.380, green: 0.408, blue: 0.455) // #616874
        static let accent    = Color(red: 0.337, green: 0.588, blue: 0.976) // #5696f9
    }

    enum Status {
        static let ok        = Color(red: 0.298, green: 0.851, blue: 0.510) // #4cd982
        static let degraded  = Color(red: 0.976, green: 0.757, blue: 0.290) // #f9c14a
        static let bad       = Color(red: 0.976, green: 0.522, blue: 0.243) // #f9853e
        static let lost      = Color(red: 0.949, green: 0.369, blue: 0.369) // #f25e5e
        static let offline   = Color(red: 0.380, green: 0.408, blue: 0.455) // #616874
    }

    // NSColor equivalents for AppKit contexts
    enum NS {
        static let base = NSColor(red: 0.098, green: 0.106, blue: 0.118, alpha: 1)
    }
}

// MARK: - Fonts

enum PMuxFonts {
    static let heading     = Font.system(size: 14, weight: .semibold, design: .rounded)
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
    static let sidebarWidth: CGFloat = 250
    static let statusBarHeight: CGFloat = 30
    static let tabBarHeight: CGFloat = 40
    static let cardPadding: CGFloat = 12
    static let cardRadius: CGFloat = 10
    static let gridGap: CGFloat = 3
    static let modalRadius: CGFloat = 14
    static let statusDotLarge: CGFloat = 8
    static let statusDotSmall: CGFloat = 6
    static let pillRadius: CGFloat = 5
}
