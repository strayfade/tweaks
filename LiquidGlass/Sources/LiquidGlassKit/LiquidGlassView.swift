//
//  LiquidGlassView.swift
//  LiquidGlass
//
//  Created by Alexey Demin on 2025-12-05.
//

import UIKit
internal import simd
internal import MetalKit
internal import MetalPerformanceShaders

struct LiquidGlass {

    /// Maximum number of rectangles supported in the shader.
    static let maxRectangles = 16

    /// Mirror the Metal 'ShaderUniforms' exactly for buffer binding.
    struct ShaderUniforms {
        var resolution: SIMD2<Float> = .zero        // Frame size in pixels.
        var contentsScale: Float = .zero            // Scale factor. 2 for Retina; 3 for Super Retina.
        var touchPoint: SIMD2<Float> = .zero        // Touch position in points (upper-left origin).
        var shapeMergeSmoothness: Float = .zero     // Specifies the distance between elements at which they begin to merge (spacing).
        var cornerRadius: Float = .zero             // Base rounding (e.g., 24 for subtle chamfer). Circle if half the side.
        var cornerRoundnessExponent: Float = 2      // 1 = diamond; 2 = circle; 4 = squircle.
        var materialTint: SIMD4<Float> = .zero      // RGBA; e.g., subtle cyan (0.2, 0.8, 1.0, 1.0)
        var glassThickness: Float                   // Fake parallax depth (e.g., 8-16 px)
        var refractiveIndex: Float                  // 1.45-1.52 for borosilicate glass feel
        var dispersionStrength: Float               // 0.0-0.02; prismatic color split on edges
        var fresnelDistanceRange: Float             // px falloff from silhouette (e.g., 32)
        var fresnelIntensity: Float                 // 0.0-1.0; rim lighting boost
        var fresnelEdgeSharpness: Float             // Power 1.0=linear, 8.0=crisp
        var glareDistanceRange: Float               // Similar to fresnel, but for specular streaks
        var glareAngleConvergence: Float            // 0.0-π; focuses rays toward light dir
        var glareOppositeSideBias: Float            // >1.0 amplifies back-side highlights
        var glareIntensity: Float                   // 1.0-4.0; bloom-like edge fire
        var glareEdgeSharpness: Float               // Matches fresnel for consistency
        var glareDirectionOffset: Float             // Radians; tilts streak asymmetry
        var rectangleCount: Int32 = .zero           // Number of active rectangles
        var rectangles: (                           // Array of rectangles (x, y, width, height) in points, upper-left origin.
            SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
            SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
            SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
            SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>
        ) = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero,
             .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    }

    let shaderUniforms: ShaderUniforms
    let backgroundTextureSizeCoefficient: Double
    let backgroundTextureScaleCoefficient: Double
    let backgroundTextureBlurRadius: Double
    var tintColor: UIColor?
    var shadowOverlay: Bool = false

    static func thumb(magnification: Double = 1) -> Self {
        .init(
            shaderUniforms: .init(
                materialTint: .init(x: 0.9, y: 0.95, z: 1.0, w: 0.15), // Near-clear with cool bias.
                glassThickness: 10,
                refractiveIndex: 1.11,
                dispersionStrength: 5,
                fresnelDistanceRange: 70,
                fresnelIntensity: 0,
                fresnelEdgeSharpness: 0,
                glareDistanceRange: 30,
                glareAngleConvergence: 0,
                glareOppositeSideBias: 0,
                glareIntensity: 0.01,
                glareEdgeSharpness: -0.2,
                glareDirectionOffset: .pi * 0.9,
            ),
            backgroundTextureSizeCoefficient: 1 / magnification,
            backgroundTextureScaleCoefficient: magnification,
            backgroundTextureBlurRadius: 0,
            shadowOverlay: true,
        )
    }

    static let lens = Self.init(
        shaderUniforms: .init(
            glassThickness: 6,
            refractiveIndex: 1.1,
            dispersionStrength: 15,
            fresnelDistanceRange: 70,
            fresnelIntensity: 0,
            fresnelEdgeSharpness: 0,
            glareDistanceRange: 30,
            glareAngleConvergence: 0.1,
            glareOppositeSideBias: 1,
            glareIntensity: 0.1,
            glareEdgeSharpness: -0.1,
            glareDirectionOffset: -.pi / 4,
        ),
        backgroundTextureSizeCoefficient: 1.1,
        backgroundTextureScaleCoefficient: 0.8,
        backgroundTextureBlurRadius: 0,
        shadowOverlay: true,
    )

    static let regular = Self.init(
        shaderUniforms: .init(
            glassThickness: 10,
            refractiveIndex: 1.5,
            dispersionStrength: 5,
            fresnelDistanceRange: 70,
            fresnelIntensity: 0,
            fresnelEdgeSharpness: 0,
            glareDistanceRange: 30,
            glareAngleConvergence: 0.1,
            glareOppositeSideBias: 1,
            glareIntensity: 0.1,
            glareEdgeSharpness: -0.15,
            glareDirectionOffset: -.pi / 4,
        ),
        backgroundTextureSizeCoefficient: 1,
        backgroundTextureScaleCoefficient: 0.5,
        backgroundTextureBlurRadius: 0.3,
        tintColor: UIColor { $0.userInterfaceStyle == .dark ? #colorLiteral(red: 0.28, green: 0.28, blue: 0.28, alpha: 0.80) : #colorLiteral(red: 0.9023525731, green: 0.9509486998, blue: 1, alpha: 0.8002892298) }
    )

    /// Same as regular but with no material tint — fully-transparent glass with only refraction.
    static let clear = Self.init(
        shaderUniforms: .init(
            materialTint: .zero,  // Explicitly zero — no white/dark tint at all
            glassThickness: 10,
            refractiveIndex: 1.5,
            dispersionStrength: 5,
            fresnelDistanceRange: 70,
            fresnelIntensity: 0,
            fresnelEdgeSharpness: 0,
            glareDistanceRange: 30,
            glareAngleConvergence: 0.1,
            glareOppositeSideBias: 1,
            glareIntensity: 0.1,
            glareEdgeSharpness: -0.15,
            glareDirectionOffset: -.pi / 4,
        ),
        backgroundTextureSizeCoefficient: 1,
        backgroundTextureScaleCoefficient: 0.2,
        backgroundTextureBlurRadius: 0.25,
        tintColor: nil
    )
}

final class BackdropView: UIView {

    override class var layerClass: AnyClass {
        // CABackdropLayer is a private API that captures content behind the layer
        NSClassFromString("CABackdropLayer") ?? CALayer.self
    }

    init() {
        super.init(frame: .zero)

        // Configure backdrop view
        isUserInteractionEnabled = false
        layer.setValue(false, forKey: "layerUsesCoreImageFilters")

        // Configure backdrop layer properties (private API)
        layer.setValue(true, forKey: "windowServerAware")
        layer.setValue(UUID().uuidString, forKey: "groupName")
//        layer.setValue(1.0, forKey: "scale")  // Full resolution for capture
//        layer.setValue(0.0, forKey: "bleedAmount")
//        layer.setValue(false, forKey: "allowsHitTesting")
//        layer.setValue(true, forKey: "captureOnly")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class ShadowView: UIView {

    init() {
        super.init(frame: .zero)

        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.compositingFilter = "multiplyBlendMode"
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let shadowRadius = 3.5
        let path = UIBezierPath(roundedRect: bounds.insetBy(dx: -1, dy: -shadowRadius / 2), cornerRadius: bounds.height / 2)
        let innerPill = UIBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: shadowRadius / 2), cornerRadius: bounds.height / 2).reversing()
        path.append(innerPill)
        layer.shadowPath = path.cgPath
        layer.shadowRadius = shadowRadius
        layer.shadowOpacity = 0.2
        layer.shadowOffset = .init(width: 0, height: shadowRadius + 2)
    }
}

final class LiquidGlassRenderer {
    @MainActor static let shared = LiquidGlassRenderer()

    let device: MTLDevice
    let pipelineState: MTLRenderPipelineState

    private(set) var capturesSuspendedUntil: CFTimeInterval = 0
    private let registeredViews = NSHashTable<LiquidGlassView>.weakObjects()

    /// Added to each view's preset `glareDirectionOffset` from device tilt (radians).
    private(set) var glareDirectionMotionOffset: Float = 0

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not supported")
        }
        self.device = device

#if SWIFT_PACKAGE
        let library = try! device.makeDefaultLibrary(bundle: .module)
#else
        // Resolve shader bundle: prefer a bundle embedded next to the binary (normal app / Swift Package
        // non-module builds), then fall back to the jailbreak tweak installation path.
        let mainBundle = Bundle(for: LiquidGlassView.self)
        let resolvedBundleURL: URL
        if let embeddedURL = mainBundle.url(forResource: "LiquidGlassKitShaderResources", withExtension: "bundle") {
            resolvedBundleURL = embeddedURL
        } else {
            // Jailbreak tweak layout – support both rootless (/var/jb prefix, Palera1n/Dopamine)
            // and rootful (no prefix, Unc0ver/Taurine).
            let jbPrefix = FileManager.default.fileExists(atPath: "/var/jb") ? "/var/jb" : ""
            resolvedBundleURL = URL(fileURLWithPath: "\(jbPrefix)/Library/LiquidGlass/LiquidGlassKitShaderResources.bundle")
        }
        guard let shaderBundle = Bundle(url: resolvedBundleURL) else {
            fatalError("[LiquidGlass] Could not open shader bundle at \(resolvedBundleURL.path)")
        }
        let library = try! device.makeDefaultLibrary(bundle: shaderBundle)
#endif

        let vertexFunction = library.makeFunction(name: "fullscreenQuad")!
        let fragmentFunction = library.makeFunction(name: "liquidGlassEffect")!

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm  // Match MTKView

        self.pipelineState = try! device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    func register(_ view: LiquidGlassView) {
        registeredViews.add(view)
        GlassMotionController.installLifecycleObserversIfNeeded()
        GlassMotionController.startIfNeeded()
    }

    @MainActor
    func updateGlareDirection(_ angle: Float) {
        glareDirectionMotionOffset = angle
        for view in registeredViews.allObjects {
            guard view.isEffectivelyVisible(), view.intersectsWindowBounds() else { continue }
            view.markUniformsDirty()
        }
    }

    func unregister(_ view: LiquidGlassView) {
        registeredViews.remove(view)
    }

    var isCaptureSuspended: Bool {
        CACurrentMediaTime() < capturesSuspendedUntil
    }

    func suspendCaptures(for duration: Double) {
        let now = CACurrentMediaTime()
        capturesSuspendedUntil = max(capturesSuspendedUntil, now + duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else { return }
            if CACurrentMediaTime() >= self.capturesSuspendedUntil {
                self.triggerGlobalBurst()
            }
        }
    }

    func triggerGlobalBurst() {
        for view in registeredViews.allObjects {
            view.captureBackground(force: true)
        }
    }

    // MARK: - Coalesced async capture (keeps MTKView draw off the layer.render path)

    private var pendingCaptureViews = NSHashTable<LiquidGlassView>.weakObjects()
    private var captureFlushScheduled = false
    /// Cap synchronous layer.render / drawHierarchy work per run-loop turn.
    private let maxCapturesPerRunLoop = 3

    func requestBackgroundCapture(_ view: LiquidGlassView) {
        pendingCaptureViews.add(view)
        scheduleCaptureFlush()
    }

    private func scheduleCaptureFlush() {
        guard !captureFlushScheduled else { return }
        captureFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushPendingCaptures()
        }
    }

    private func flushPendingCaptures() {
        captureFlushScheduled = false

        let views = pendingCaptureViews.allObjects
        guard !views.isEmpty else { return }

        var performed = 0
        var rescheduled = false
        for view in views {
            pendingCaptureViews.remove(view)
            if performed >= maxCapturesPerRunLoop {
                pendingCaptureViews.add(view)
                rescheduled = true
                continue
            }
            if view.performScheduledCapture() {
                performed += 1
            }
        }
        if rescheduled {
            scheduleCaptureFlush()
        }
    }
}

final class LiquidGlassView: MTKView {

    let liquidGlass: LiquidGlass

    var commandQueue: MTLCommandQueue!
    var uniformsBuffer: MTLBuffer!
    var zeroCopyBridge: ZeroCopyBridge!

    // Background texture for the shader
    private var backgroundTexture: MTLTexture?

    /// Whether to automatically capture superview on each frame. 
    /// Set to false for manual control via `captureBackground()`.
    var autoCapture: Bool = true

    var touchPoint: CGPoint? = nil {
        didSet { uniformsDirty = true }
    }

    var frames: [CGRect] = [] {
        didSet { uniformsDirty = true }
    }

    // Throttle background capture: tracks last capture time to avoid per-frame CPU burn.
    private var lastCaptureTime: CFTimeInterval = 0
    /// Last on-screen anchor used to skip capture when the glass view has not moved.
    private var lastCaptureAnchor: (mid: CGPoint, size: CGSize)?
    /// Maximum capture rate while the glass is still.
    var maxCapturesPerSecond: Double = DeviceCapability.maxCapturesPerSecond
    /// Higher cap while the view is moving on-screen (scroll, animation).
    var maxCapturesPerSecondWhileMoving: Double = DeviceCapability.maxCapturesPerSecondWhileMoving

    private var capturePending = false
    private var recentAnchorDelta: CGFloat = 0

    private var gaussianBlur: MPSImageGaussianBlur?
    private var gaussianBlurSigma: Float = -1
    private var uniformsDirty = true
    private var lastLayoutBounds: CGRect = .zero
    /// False while clipped off-screen or detached; used to refresh capture when re-visible.
    private var wasIntersectingWindow = false
    /// Set when the view leaves the window or is covered; cleared after a successful capture.
    private var needsVisibilityRefresh = false
    /// Last time `draw` saw this view intersect the window (0 while off-screen).
    private var lastSeenVisibleTime: CFTimeInterval = 0

    // Shadow overlay subview
    private weak var shadowView: ShadowView?

    // Backdrop capture view (stays in superview, contains only CABackdropLayer)
    private let backdropView = BackdropView()

    init(_ liquidGlass: LiquidGlass) {
        self.liquidGlass = liquidGlass

        super.init(frame: .zero, device: LiquidGlassRenderer.shared.device)
        LiquidGlassRenderer.shared.register(self)
        
        if liquidGlass.shadowOverlay {
            let shadowView = ShadowView()
            addSubview(shadowView)
            self.shadowView = shadowView
        }
        setupMetal()
//        layer.shouldRasterize = true
//        clipsToBounds = true
//        autoResizeDrawable = false
//        contentMode = .center
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        LiquidGlassRenderer.shared.unregister(self)
    }

    func setupMetal() {
        guard let device else { return }

        commandQueue = device.makeCommandQueue()!

        // Uniforms buffer (update per frame)
        uniformsBuffer = device.makeBuffer(length: MemoryLayout<LiquidGlass.ShaderUniforms>.stride, options: [])!

        zeroCopyBridge = .init(device: device)

        // Make view transparent so we can see the effect
        isOpaque = false
        layer.isOpaque = false

        syncRenderingPauseState()
        preferredFramesPerSecond = DeviceCapability.metalRenderFPS
//        enableSetNeedsDisplay = true  // Allow setNeedsDisplay() to trigger draws
    }

    // MARK: - Background Capture

    func markUniformsDirty() {
        uniformsDirty = true
    }

    /// Drop cached capture position so the next tick re-samples the background.
    func invalidateCaptureCache() {
        lastCaptureAnchor = nil
        wasIntersectingWindow = false
        needsVisibilityRefresh = true
        lastSeenVisibleTime = 0
        recentAnchorDelta = 0
        uniformsDirty = true
        markCaptureNeeded()
    }

    /// Call when the host is shown again after being hidden, covered, or scrolled away.
    func noteHostBecameVisible() {
        needsVisibilityRefresh = true
        lastCaptureAnchor = nil
        syncRenderingPauseState()
        markCaptureNeeded()
    }

    /// Call when the host is hidden, removed, or fully transparent.
    func noteVisibilityPaused() {
        needsVisibilityRefresh = true
        wasIntersectingWindow = false
        syncRenderingPauseState()
    }

    /// Stops MTKView draws when clipped off-screen — largest SpringBoard win (NC scroll, etc.).
    func syncRenderingPauseState() {
        isPaused = !isEffectivelyVisible() || !intersectsWindowBounds()
    }

    /// Queue a background sample without blocking the current Metal draw.
    func markCaptureNeeded() {
        capturePending = true
        LiquidGlassRenderer.shared.requestBackgroundCapture(self)
    }

    /// Schedule first paint once layout has produced a real buffer (no-op when texture exists).
    func ensureInitialCaptureScheduled() {
        guard backgroundTexture == nil, bounds.width > 0, bounds.height > 0 else { return }
        markCaptureNeeded()
    }

    /// Called from the renderer's async capture flush (not from `draw`).
    func performScheduledCapture() -> Bool {
        guard intersectsWindowBounds() else { return false }
        guard needsBackgroundCapture() else {
            if !needsVisibilityRefresh { capturePending = false }
            return false
        }
        let forceCapture = backgroundTexture == nil || needsVisibilityRefresh
        let didCapture = captureBackground(force: forceCapture)
        if didCapture {
            capturePending = false
            needsVisibilityRefresh = false
        } else if !needsBackgroundCapture(), !needsVisibilityRefresh {
            capturePending = false
        }
        return didCapture
    }

    private func needsBackgroundCapture() -> Bool {
        if backgroundTexture == nil { return true }
        if needsVisibilityRefresh { return true }
        return capturePending || captureAnchorMovedEnough(force: false)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            invalidateCaptureCache()
        } else {
            wasIntersectingWindow = false
            needsVisibilityRefresh = true
            lastSeenVisibleTime = 0
        }
        syncRenderingPauseState()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview != nil {
            invalidateCaptureCache()
        } else {
            needsVisibilityRefresh = true
        }
    }

    override var isHidden: Bool {
        didSet {
            if !isHidden { invalidateCaptureCache() }
        }
    }

    /// Whether this view is on-screen enough to show glass (ancestor hidden/transparent excluded).
    func isEffectivelyVisible() -> Bool {
        var view: UIView? = self
        while let v = view {
            if v.isHidden || v.alpha < 0.01 { return false }
            view = v.superview
        }
        return window != nil
    }

    /// Frame intersects the window — false when scrolled off-screen while still in the hierarchy.
    func intersectsWindowBounds() -> Bool {
        guard isEffectivelyVisible(),
              let window,
              bounds.width > 0, bounds.height > 0 else { return false }
        let frameInWindow = convert(bounds, to: window)
        guard frameInWindow.width.isFinite, frameInWindow.height.isFinite else { return false }
        return frameInWindow.intersects(window.bounds)
    }

    private func noteVisibilityForCapture() {
        let intersects = intersectsWindowBounds()
        if intersects {
            if !wasIntersectingWindow || needsVisibilityRefresh {
                lastCaptureAnchor = nil
                markCaptureNeeded()
            }
            lastSeenVisibleTime = CACurrentMediaTime()
            wasIntersectingWindow = true
        } else if wasIntersectingWindow {
            needsVisibilityRefresh = true
            wasIntersectingWindow = false
        }
        syncRenderingPauseState()
    }

    /// On-screen anchor in window coordinates (tracks scroll / animation, not just local layout).
    private func currentCaptureAnchor() -> (mid: CGPoint, size: CGSize)? {
        let currentLayer = layer.presentation() ?? layer
        if let window {
            let frameInWindow = currentLayer.convert(currentLayer.bounds, to: window.layer)
            guard frameInWindow.width.isFinite, frameInWindow.height.isFinite,
                  frameInWindow.width > 0, frameInWindow.height > 0,
                  frameInWindow.midX.isFinite, frameInWindow.midY.isFinite else { return nil }
            return (CGPoint(x: frameInWindow.midX, y: frameInWindow.midY), frameInWindow.size)
        }
        if let rootView = findRootView() {
            let frameInRoot = currentLayer.convert(currentLayer.bounds, to: rootView.layer)
            guard frameInRoot.width.isFinite, frameInRoot.height.isFinite,
                  frameInRoot.width > 0, frameInRoot.height > 0 else { return nil }
            return (CGPoint(x: frameInRoot.midX, y: frameInRoot.midY), frameInRoot.size)
        }
        return nil
    }

    private func captureAnchorMovedEnough(force: Bool) -> Bool {
        guard !force, let anchor = currentCaptureAnchor(), let last = lastCaptureAnchor else { return true }
        let dx = anchor.mid.x - last.mid.x
        let dy = anchor.mid.y - last.mid.y
        recentAnchorDelta = hypot(dx, dy)
        let positionEpsilon: CGFloat = recentAnchorDelta > 3 ? 0.25 : 0.5
        let sizeEpsilon: CGFloat = 0.5
        return abs(dx) > positionEpsilon
            || abs(dy) > positionEpsilon
            || abs(anchor.size.width - last.size.width) > sizeEpsilon
            || abs(anchor.size.height - last.size.height) > sizeEpsilon
    }

    private func effectiveMaxCapturesPerSecond() -> Double {
        if recentAnchorDelta > 6 { return maxCapturesPerSecondWhileMoving }
        if recentAnchorDelta > 1.5 { return (maxCapturesPerSecond + maxCapturesPerSecondWhileMoving) * 0.5 }
        return maxCapturesPerSecond
    }

    /// Returns true when a new background texture was captured and blurred (when blur radius > 0).
    @discardableResult
    func captureBackground(force: Bool = false) -> Bool {
        let needsTexture = backgroundTexture == nil
        if !force {
            if LiquidGlassRenderer.shared.isCaptureSuspended, !needsTexture { return false }
            if !needsTexture, !captureAnchorMovedEnough(force: false) { return false }
        }

        let now = CACurrentMediaTime()
        let minInterval = 1.0 / effectiveMaxCapturesPerSecond()
        guard force || needsTexture || now - lastCaptureTime >= minInterval else { return false }

        guard bounds.width > 0, bounds.height > 0,
              zeroCopyBridge.pixelBuffer != nil else { return false }

        if #available(iOS 26.2, *) {
            captureRootView()
        } else {
            captureBackdrop()
        }

        guard backgroundTexture != nil else { return false }
        applyBackgroundBlurIfNeeded()
        lastCaptureTime = now
        if let anchor = currentCaptureAnchor() {
            lastCaptureAnchor = anchor
        }
        needsVisibilityRefresh = false
        return true
    }

    /// Captures the background content via root View using (presentation) Layer render.
    /// High CPU usage.
    func captureRootView() {
        guard let rootView = findRootView() else { return }

        let sizeCoefficient = liquidGlass.backgroundTextureSizeCoefficient
        let scaleCoefficient = layer.contentsScale * liquidGlass.backgroundTextureScaleCoefficient

        // Determine our on-screen rect in the root view coordinate space.
        // IMPORTANT: During `UIView.animate`, the view's *model* layer jumps to the final frame
        // immediately; the in-flight position lives in the *presentation* layer. Using the
        // presentation layer makes the captured background track the view while it animates.
        let currentLayer = layer.presentation() ?? layer
        let frameInRoot = currentLayer.convert(currentLayer.bounds, to: rootView.layer)

        // Expand capture area around the MTKView center (in root view coordinates)
        let captureSize = CGSize(width: frameInRoot.width * sizeCoefficient,
                                 height: frameInRoot.height * sizeCoefficient)
        let captureRectInRoot = CGRect(x: frameInRoot.midX - captureSize.width / 2,
                                       y: frameInRoot.midY - captureSize.height / 2,
                                       width: captureSize.width,
                                       height: captureSize.height)

        // Same NaN guard as captureBackdrop — presentation layer can have NaN position.
        guard captureSize.width.isFinite, captureSize.height.isFinite,
              captureSize.width > 0, captureSize.height > 0,
              captureRectInRoot.origin.x.isFinite, captureRectInRoot.origin.y.isFinite else { return }

        backgroundTexture = zeroCopyBridge.render { context in
            // Temporarily set opacity to 0 so *this* view renders as transparent in the
            // captured background — the same effect as isHidden but without telling the
            // window server to composite a hidden layer, which is the primary flicker source.
            // Both model changes are batched in a single CATransaction so the render server
            // never sees the zero-opacity state on screen.
            let savedOpacity = layer.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = 0

            context.scaleBy(x: scaleCoefficient, y: scaleCoefficient)
            context.translateBy(x: -captureRectInRoot.origin.x, y: -captureRectInRoot.origin.y)

            let rootViewLayer = rootView.layer.presentation() ?? rootView.layer
            rootViewLayer.render(in: context)

            layer.opacity = savedOpacity
            CATransaction.commit()
        }

    }

    /// Captures the background content via CABackdropLayer using drawHierarchy.
    /// Noticeable rendering delay.
    func captureBackdrop() {
        guard let superview else { return }
        
        let sizeCoefficient = liquidGlass.backgroundTextureSizeCoefficient
        let scaleCoefficient = layer.contentsScale * liquidGlass.backgroundTextureScaleCoefficient

        // Calculate frame using presentation layer for smooth animation tracking
        let currentLayer = layer.presentation() ?? layer
        let frameInSuperview = currentLayer.convert(currentLayer.bounds, to: superview.layer)
        let captureSize = CGSize(width: frameInSuperview.width * sizeCoefficient,
                                 height: frameInSuperview.height * sizeCoefficient)
        let captureOrigin = CGPoint(x: frameInSuperview.midX - captureSize.width / 2,
                                    y: frameInSuperview.midY - captureSize.height / 2)

        // Guard against NaN — presentation layer can return NaN position during
        // mid-animation transitions (e.g. iPhone X home-screen). Setting a NaN frame
        // on CABackdropLayer throws CALayerInvalidGeometry and crashes SpringBoard.
        guard captureSize.width.isFinite, captureSize.height.isFinite,
              captureSize.width > 0, captureSize.height > 0,
              captureOrigin.x.isFinite, captureOrigin.y.isFinite else { return }

        let backdropFrame = CGRect(origin: captureOrigin, size: captureSize)
        if backdropView.frame != backdropFrame {
            backdropView.frame = backdropFrame
        }

        if backdropView.superview !== superview {
            superview.insertSubview(backdropView, belowSubview: self)
        }
        
        // Capture using drawHierarchy (gets windowserver-composited content)
        backgroundTexture = zeroCopyBridge.render { context in
            context.scaleBy(x: scaleCoefficient, y: scaleCoefficient)

            UIGraphicsPushContext(context)
            backdropView.drawHierarchy(in: backdropView.bounds, afterScreenUpdates: false)
            UIGraphicsPopContext()
        }

    }

    private func prepareGaussianBlurIfNeeded() -> MPSImageGaussianBlur? {
        guard liquidGlass.backgroundTextureBlurRadius > 0, let device else { return nil }
        let sigma = Float(liquidGlass.backgroundTextureBlurRadius * layer.contentsScale)
        if gaussianBlur == nil || abs(gaussianBlurSigma - sigma) > 0.01 {
            gaussianBlur = MPSImageGaussianBlur(device: device, sigma: sigma)
            gaussianBlur?.edgeMode = .clamp
            gaussianBlurSigma = sigma
        }
        return gaussianBlur
    }

    /// Applies the user-configured Gaussian blur to the captured background texture.
    /// Must run after every successful capture — direct `captureBackground(force:)` callers
    /// bypass `performScheduledCapture`, which previously was the only blur entry point.
    private func applyBackgroundBlurIfNeeded() {
        guard liquidGlass.backgroundTextureBlurRadius > 0 else { return }
        guard var backgroundTexture,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blur = prepareGaussianBlurIfNeeded() else { return }
        blur.encode(commandBuffer: commandBuffer, inPlaceTexture: &backgroundTexture, fallbackCopyAllocator: nil)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    func updateUniforms() {
        var uniforms = liquidGlass.shaderUniforms
        let scaleFactor = layer.contentsScale

        uniforms.resolution = .init(x: Float(bounds.width * scaleFactor),
                                    y: Float(bounds.height * scaleFactor))
        uniforms.contentsScale = Float(scaleFactor)

        uniforms.shapeMergeSmoothness = 0.2

        // Assign rectangles from frames array, or use bounds if empty
        let effectiveFrames = frames.isEmpty ? [bounds] : frames
        uniforms.rectangleCount = Int32(min(effectiveFrames.count, LiquidGlass.maxRectangles))

        // Convert CGRect frames to SIMD4<Float> (x, y, width, height)
        var rects: [SIMD4<Float>] = []
        for i in 0..<LiquidGlass.maxRectangles {
            if i < effectiveFrames.count {
                let frame = effectiveFrames[i]
                rects.append(SIMD4<Float>(
                    Float(frame.origin.x),
                    Float(frame.origin.y),
                    Float(frame.width),
                    Float(frame.height)
                ))
            } else {
                rects.append(.zero)
            }
        }
        uniforms.rectangles = (
            rects[0], rects[1], rects[2], rects[3],
            rects[4], rects[5], rects[6], rects[7],
            rects[8], rects[9], rects[10], rects[11],
            rects[12], rects[13], rects[14], rects[15]
        )

        if let touchPoint {
            uniforms.touchPoint = .init(x: Float(touchPoint.x), y: Float(touchPoint.y))
        }

//        uniforms.cornerRoundnessExponent = (layer.cornerCurve == .continuous) ? 4 : 2
        uniforms.cornerRadius = Float(layer.cornerRadius)

        if let tintColor = liquidGlass.tintColor {
            uniforms.materialTint = tintColor.toSimdFloat4()
        }

        uniforms.glareDirectionOffset += LiquidGlassRenderer.shared.glareDirectionMotionOffset

        uniformsBuffer.contents().assumingMemoryBound(to: LiquidGlass.ShaderUniforms.self).pointee = uniforms

//        setNeedsDisplay()
//        draw(bounds)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        if lastLayoutBounds != bounds {
            lastLayoutBounds = bounds
            uniformsDirty = true
            lastCaptureAnchor = nil
        }

        let scale = layer.contentsScale * liquidGlass.backgroundTextureSizeCoefficient * liquidGlass.backgroundTextureScaleCoefficient
        let newWidth  = Int(bounds.width  * scale)
        let newHeight = Int(bounds.height * scale)

        // Only recreate the CVPixelBuffer / Metal texture when dimensions actually change.
        // Recreating on every layoutSubviews (which fires during animations) creates and
        // destroys Metal resources at display-refresh rate, spiking memory allocator pressure.
        let currentWidth  = zeroCopyBridge.pixelBuffer.map(CVPixelBufferGetWidth)  ?? 0
        let currentHeight = zeroCopyBridge.pixelBuffer.map(CVPixelBufferGetHeight) ?? 0
        if newWidth != currentWidth || newHeight != currentHeight, newWidth > 0, newHeight > 0 {
            zeroCopyBridge.setupBuffer(width: newWidth, height: newHeight)
            backgroundTexture = nil
            lastCaptureAnchor = nil
            markCaptureNeeded()
        } else if backgroundTexture == nil, newWidth > 0, newHeight > 0, window != nil {
            markCaptureNeeded()
        }

        if intersectsWindowBounds(), needsVisibilityRefresh {
            markCaptureNeeded()
        }

        syncRenderingPauseState()
        shadowView?.frame = bounds
    }

    override func draw(_ rect: CGRect) {
        if uniformsDirty {
            updateUniforms()
            uniformsDirty = false
        }

        if autoCapture {
            noteVisibilityForCapture()
            if needsBackgroundCapture(),
               !LiquidGlassRenderer.shared.isCaptureSuspended || backgroundTexture == nil {
                markCaptureNeeded()
            }
        }

        guard let drawable = currentDrawable,
              let renderPassDesc = currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else { return }

        encoder.setRenderPipelineState(LiquidGlassRenderer.shared.pipelineState)
        encoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)
        
        if let texture = backgroundTexture {
            encoder.setFragmentTexture(texture, index: 0)
        }

        // Draw fullscreen quad (vertices generated in vertex shader)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

extension UIColor {
    func toSimdFloat4() -> SIMD4<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return .init(x: Float(r), y: Float(g), z: Float(b), w: Float(a))
    }
}

// Helpers: Lerp for damping, UIColor to Half4
//private func lerp(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ t: Float) -> SIMD2<Float> {
//    return a * (1 - t) + b * t
//}

extension UIView {
    /// Finds the root view in the view hierarchy.
    func findRootView() -> UIView? {
        var current: UIView? = superview
        while let parent = current?.superview {
            current = parent
        }
        return current
    }
}
