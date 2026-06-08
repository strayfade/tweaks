//
//  GlassPreferences.swift
//  LiquidGlass
//
//  Reads "Glass Display" slider values from the preferences suite.
//

import Foundation

enum GlassDisplayPreferences {
    private static let suiteName = "com.strayfade.liquidglass~prefs"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    private static func double(_ key: String, default defaultValue: Double) -> Double {
        guard let defaults,
              let obj = defaults.object(forKey: key) else { return defaultValue }
        if let n = obj as? NSNumber { return n.doubleValue }
        return defaultValue
    }

    /// Blur slider 0–1000; default 25 matches legacy renderer tuning.
    static var blurAmount: Double { double("GlassBlur", default: 25) }

    /// Extra blur multiplier for context menus and alert dialogs.
    static let overlayBlurMultiplier: Double = 5

    /// Multiplier for `backgroundTextureBlurRadius`; 1.0 at the default slider position.
    static var blurRadiusMultiplier: Double {
        let amount = blurAmount
        if amount <= 0 { return 0 }
        return amount / 25.0
    }

    /// Render resolution slider 10–100 (%); default 20 matches `.clear` capture scale.
    static var renderScalePercent: Double { double("GlassScale", default: 20) }

    static var scaleCoefficientMultiplier: Double {
        max(0.1, renderScalePercent / 20.0)
    }

    static var edgeThickness: Double { double("GlassThickness", default: 10) }

    /// Refraction slider 100–200; default 150 → refractive index 1.5.
    static var refractionAmount: Double { double("GlassRefractiveIndex", default: 150) }

    static var refractiveIndex: Double {
        1.0 + (refractionAmount - 100.0) / 100.0
    }

    static var dispersion: Double { double("GlassDispersion", default: 5) }

    /// Edge glint slider 0–50; default 10 → glare intensity 0.1.
    static var glareAmount: Double { double("GlassGlare", default: 10) }

    static var glareIntensity: Double { glareAmount / 100.0 }
}
