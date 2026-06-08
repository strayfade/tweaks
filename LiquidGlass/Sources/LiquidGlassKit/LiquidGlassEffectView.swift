//
//  LiquidGlassEffectView.swift
//  LiquidGlass
//
//  Created by Alexey Demin on 2025-12-23.
//

import UIKit

public class LiquidGlassEffectView: UIView, AnyVisualEffectView {

    public let contentView = UIView()
    public var effect: UIVisualEffect?

    var liquidGlassView: LiquidGlassView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let liquidGlassView {
                insertSubview(liquidGlassView, belowSubview: contentView)
            }
        }
    }

    public required init(effect: LiquidGlassEffect) {
        self.effect = effect

        super.init(frame: .zero)

        let liquidGlassView = LiquidGlassView(effect.resolvedLiquidGlass())
        addSubview(liquidGlassView)
        self.liquidGlassView = liquidGlassView
        
        setupContentView()
    }

    public required init(effect: LiquidGlassContainerEffect) {
        self.effect = effect

        super.init(frame: .zero)

        setupContentView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setupContentView() {
        addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    public override func layoutSubviews() {
        super.layoutSubviews()

        liquidGlassView?.frame = contentView.frame
        liquidGlassView?.layer.cornerRadius = layer.cornerRadius
        liquidGlassView?.layer.cornerCurve = layer.cornerCurve

        guard window != nil, !isHidden, alpha > 0.01 else {
            liquidGlassView?.syncRenderingPauseState()
            return
        }
        liquidGlassView?.ensureInitialCaptureScheduled()
        liquidGlassView?.syncRenderingPauseState()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            liquidGlassView?.invalidateCaptureCache()
        } else {
            liquidGlassView?.noteVisibilityPaused()
        }
        liquidGlassView?.syncRenderingPauseState()
    }

    public override var isHidden: Bool {
        didSet {
            if isHidden {
                liquidGlassView?.noteVisibilityPaused()
            } else {
                liquidGlassView?.noteHostBecameVisible()
            }
        }
    }

    public override var alpha: CGFloat {
        didSet {
            if alpha < 0.01 {
                liquidGlassView?.noteVisibilityPaused()
            } else if !isHidden, window != nil {
                liquidGlassView?.noteHostBecameVisible()
            }
        }
    }

    func captureBackground() {
        liquidGlassView?.captureBackground(force: true)
    }
}

/// A visual effect that renders a glass material.
public class LiquidGlassEffect: UIVisualEffect {

    public enum Style {
        case regular, clear, regularHighBlur, clearBlur

        var liquidGlass: LiquidGlass {
            switch self {
            case .regular, .regularHighBlur: .regular
            case .clear, .clearBlur: .clear
            }
        }
    }
    let style: Style

    let isNative: Bool

    /// Enables interactive behavior for the glass effect.
    public var isInteractive = false

    /// A tint color applied to the glass.
    public var tintColor: UIColor?

    /// When true, use higher-quality background capture settings.
    public var fullQuality = false

    /// Multiplies user blur (e.g. 5× for context menus and alert dialogs).
    public var blurMultiplier: Double = 1

    func resolvedLiquidGlass() -> LiquidGlass {
        let base = style.liquidGlass
        var blur = base.backgroundTextureBlurRadius
        var scale = base.backgroundTextureScaleCoefficient
        switch style {
        case .regularHighBlur:
            blur = max(blur, 0.45)
            scale = max(scale, fullQuality ? 0.5 : 0.35)
        case .clearBlur:
            blur = max(blur, 0.35)
            scale = max(scale, fullQuality ? 0.4 : 0.25)
        case .clear:
            // Match .regular capture quality (see bridge comments) so the blur slider has a real baseline.
            blur = max(blur, 0.5)
            scale = max(scale, 0.5)
        default:
            if fullQuality {
                scale = max(scale, 0.5)
            }
        }

        let prefs = GlassDisplayPreferences.self
        let totalBlurMultiplier = prefs.blurRadiusMultiplier * blurMultiplier
        if totalBlurMultiplier == 0 {
            blur = 0
        } else if blur > 0 {
            blur *= totalBlurMultiplier
        } else {
            // Styles with no built-in radius still honor the blur slider.
            blur = 0.3 * totalBlurMultiplier
        }
        scale *= prefs.scaleCoefficientMultiplier

        var uniforms = base.shaderUniforms
        uniforms.glassThickness = Float(prefs.edgeThickness)
        uniforms.refractiveIndex = Float(prefs.refractiveIndex)
        uniforms.dispersionStrength = Float(prefs.dispersion)
        uniforms.glareIntensity = Float(prefs.glareIntensity)

        return LiquidGlass(
            shaderUniforms: uniforms,
            backgroundTextureSizeCoefficient: base.backgroundTextureSizeCoefficient,
            backgroundTextureScaleCoefficient: scale,
            backgroundTextureBlurRadius: blur,
            tintColor: tintColor ?? base.tintColor,
            shadowOverlay: base.shadowOverlay
        )
    }

    /// Creates a glass effect with the specified style.
    /// - Parameters:
    ///   - style: The glass effect style.
    ///   - isNative: Whether to use `UIGlassEffect` on iOS 26+.
    public init(style: Style, isNative: Bool = true) {
        self.style = style
        self.isNative = isNative
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A `LiquidGlassContainerEffect` renders multiple glass elements into a combined effect.
///
/// When using `LiquidGlassContainerEffect` with a `VisualEffectView` you can
/// add individual glass elements to the visual effect view's contentView by nesting `VisualEffectView`'s
/// configured with `LiquidGlassEffect`. In that configuration, the glass container will render all glass elements
/// in one combined view, behind the visual effect view's `contentView`.
public class LiquidGlassContainerEffect: UIVisualEffect {

    let isNative: Bool

    /// The spacing specifies the distance between elements at which they begin to merge.
    public var spacing = 10.0

    /// Creates a combined glass effect.
    /// - Parameters:
    ///   - isNative: Whether to use `UIGlassContainerEffect` on iOS 26+.
    public init(isNative: Bool = true) {
        self.isNative = isNative
        super.init()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

public protocol AnyVisualEffectView: UIView {
    var contentView: UIView { get }
    var effect: UIVisualEffect? { get set }
}

extension UIVisualEffectView: AnyVisualEffectView { }

public func VisualEffectView(effect: UIVisualEffect?) -> AnyVisualEffectView {
    if let effect = effect as? LiquidGlassEffect {
        return LiquidGlassEffectView(effect: effect)
    } else if let effect = effect as? LiquidGlassContainerEffect {
        return LiquidGlassEffectView(effect: effect)
    } else {
        return UIVisualEffectView(effect: effect)
    }
}
