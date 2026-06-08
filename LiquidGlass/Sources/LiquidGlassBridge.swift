//
//  LiquidGlassBridge.swift  –  LiquidGlass
//  Dock glass. Reads the enabled pref from Settings.
//

import UIKit
import Darwin

// MARK: - Device capability (adaptive quality)

/// Detects A11 (iPhone X / 8-series) and older as "low-end" for glass-rendering decisions.
enum DeviceCapability {
    static let isLowEnd: Bool = {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        let model = String(cString: buf)
        // iPhone10,x = A11 (iPhone X / 8). Anything ≤ 10 (major part) is A11 or older.
        if model.hasPrefix("iPhone"),
           let major = model.dropFirst("iPhone".count).split(separator: ",").first.flatMap({ Int($0) }) {
            return major <= 10
        }
        return false
    }()

    /// Tint alpha — reduces compositing pressure on older GPUs.
    /// Tint alpha — reduces compositing pressure on older GPUs.
    static let tintAlpha: CGFloat = isLowEnd ? 0.12 : 0.28

    /// Whether the device runs at 120 Hz (ProMotion).
    static let is120Hz: Bool = UIScreen.main.maximumFramesPerSecond >= 120

    /// Target FPS for the glass display link (frame/corner sync only — not Metal draws):
    ///   120 Hz → 60 fps (enough for CC/NC motion without eating ProMotion budget)
    ///    60 Hz → 45 fps
    ///   low-end → 30 fps
    static let preferredFPS: Int = {
        if isLowEnd { return 30 }
        return is120Hz ? 60 : 45
    }()

    /// MTKView draw rate — glass refraction is static when the host is still.
    static let metalRenderFPS: Int = {
        if isLowEnd { return 20 }
        return is120Hz ? 30 : 24
    }()

    static let maxCapturesPerSecond: Double = isLowEnd ? 15 : 22
    static let maxCapturesPerSecondWhileMoving: Double = isLowEnd ? 28 : 38
}

// MARK: - GlassDisplayLink — real-time frame sync for notification + app library glass

/// Drives per-frame frame/cornerRadius synchronisation for registered glass view pairs.
/// Keeps reflections locked to the host view's bounds at display refresh rate instead of
/// relying on layoutSubviews, which fires at a lower and irregular frequency during scrolling.
private final class GlassDisplayLink {
    static let shared = GlassDisplayLink()

    private init() {
        // Stop the display link when the screen turns off or SpringBoard resigns active.
        // NOTE: SpringBoard never receives didEnterBackgroundNotification (it is always
        // the frontmost process). willResignActiveNotification fires for all scenarios
        // that should stop glass work: screen lock (power button), CC/NC overlay, etc.
        NotificationCenter.default.addObserver(
            self, selector: #selector(suspend),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(resume),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    // Caches last-written values so we never touch a CALayer when nothing changed.
    // Using a struct array instead of a Dictionary<ObjectIdentifier, Entry> is
    // measurably faster in a 60–75 fps hot path (no hash overhead, cache-friendly).
    private struct Entry {
        weak var host:  UIView?
        weak var glass: LiquidGlassEffectView?
        let fallbackR: CGFloat
        var continuousBackgroundCapture: Bool
        var lastBounds: CGRect  = .zero
        var lastR:      CGFloat = 0
        /// Host center in window space — detects scroll without local superview motion.
        var lastHostWindowMid: CGPoint?
        var hostWasIntersectingWindow = false
    }

    private var entries: [Entry] = []
    private var link: CADisplayLink?
    private var suspended = false

    // Proxy breaks the CADisplayLink ↔ GlassDisplayLink retain cycle.
    private final class Proxy: NSObject {
        weak var owner: GlassDisplayLink?
        @objc func tick() { owner?.tickAll() }
    }

    // MARK: Registration

    func register(host: UIView, glass: LiquidGlassEffectView, fallbackR: CGFloat,
                  continuousBackgroundCapture: Bool = false) {
        if let idx = entries.firstIndex(where: { $0.host === host }) {
            let existing = entries[idx]
            if existing.glass === glass,
               existing.fallbackR == fallbackR,
               existing.continuousBackgroundCapture == continuousBackgroundCapture {
                return
            }
            entries[idx] = Entry(host: host, glass: glass, fallbackR: fallbackR,
                                 continuousBackgroundCapture: continuousBackgroundCapture)
        } else {
            entries.append(Entry(host: host, glass: glass, fallbackR: fallbackR,
                                 continuousBackgroundCapture: continuousBackgroundCapture))
        }
        if !suspended { ensureLink() }
    }

    func unregister(host: UIView) {
        entries.removeAll { $0.host === host || $0.host == nil }
        if entries.isEmpty { stopLink() }
    }

    // MARK: CADisplayLink lifecycle

    private func ensureLink() {
        guard link == nil else { return }
        let proxy = Proxy()
        proxy.owner = self
        let dl = CADisplayLink(target: proxy, selector: #selector(Proxy.tick))
        let fps = DeviceCapability.preferredFPS
        if #available(iOS 15.0, *) {
            dl.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(fps) * 0.8,
                maximum: Float(fps),
                preferred: Float(fps)
            )
        } else {
            dl.preferredFramesPerSecond = fps
        }
        dl.add(to: .main, forMode: .common)
        link = dl
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func suspend() { suspended = true;  stopLink() }
    @objc private func resume()  { suspended = false; if !entries.isEmpty { ensureLink() } }

    private func hostIntersectsWindow(_ host: UIView) -> Bool {
        guard let window = host.window, !host.isHidden, host.alpha > 0.01,
              host.bounds.width > 0 else { return false }
        let frameInWindow = host.convert(host.bounds, to: window)
        guard frameInWindow.width.isFinite, frameInWindow.height.isFinite else { return false }
        return frameInWindow.intersects(window.bounds)
    }

    // MARK: Per-frame update — runs at DeviceCapability.preferredFPS

    fileprivate func tickAll() {
        guard !entries.isEmpty else { stopLink(); return }

        // One CATransaction for the entire tick — disabling implicit animations removes
        // ~5–15 µs of animation-setup overhead per CALayer write per frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        var i = 0
        while i < entries.count {
            // Dead entry (host or glass was deallocated) — remove and continue.
            guard entries[i].host != nil, entries[i].glass != nil else {
                entries.remove(at: i); continue
            }
            let host = entries[i].host!
            let gv   = entries[i].glass!

            // Remove entries whose host has left the window (e.g. App Library dismissed).
            // They will be re-registered via didMoveToWindow when the view re-appears.
            // Views that still have a window but zero bounds (mid-layout) are kept.
            guard host.window != nil else { entries.remove(at: i); continue }
            guard host.bounds.width > 0 else { i += 1; continue }

            let hostVisible = hostIntersectsWindow(host)
            if hostVisible, !entries[i].hostWasIntersectingWindow {
                gv.liquidGlassView?.noteHostBecameVisible()
            } else if !hostVisible, entries[i].hostWasIntersectingWindow {
                gv.liquidGlassView?.noteVisibilityPaused()
            }
            entries[i].hostWasIntersectingWindow = hostVisible

            // Off-screen hosts: visibility bookkeeping only — skip layer writes and captures.
            guard hostVisible else { i += 1; continue }

            let presentationLayer = host.layer.presentation()
            let b = presentationLayer?.bounds ?? host.bounds
            let r: CGFloat = {
                let candidate = presentationLayer?.cornerRadius ?? host.layer.cornerRadius
                return candidate > 0.5 ? candidate : entries[i].fallbackR
            }()

            // Only write to CALayer when the value actually changed.
            // Even with disableActions, a layer property set marks the layer as needing
            // re-composite on the render server — skipping it is a real win.
            if entries[i].lastBounds != b {
                gv.frame = b
                entries[i].lastBounds = b
            }
            if abs(entries[i].lastR - r) > 0.5 {
                gv.layer.cornerRadius = r
                entries[i].lastR = r
            }

            if entries[i].continuousBackgroundCapture {
                gv.liquidGlassView?.markCaptureNeeded()
            } else if let window = host.window {
                let hostLayer = host.layer.presentation() ?? host.layer
                let frameInWindow = hostLayer.convert(hostLayer.bounds, to: window.layer)
                let mid = CGPoint(x: frameInWindow.midX, y: frameInWindow.midY)
                if frameInWindow.midX.isFinite, frameInWindow.midY.isFinite {
                    if let lastMid = entries[i].lastHostWindowMid {
                        let dx = mid.x - lastMid.x
                        let dy = mid.y - lastMid.y
                        if dx * dx + dy * dy > 0.25 {
                            gv.liquidGlassView?.markCaptureNeeded()
                        }
                    }
                    entries[i].lastHostWindowMid = mid
                }
            }

            i += 1
        }

        CATransaction.commit()
        if entries.isEmpty { stopLink() }
    }
}

// MARK: - Preferences
private let kSuite = "com.strayfade.liquidglass~prefs"
private let kPrefsLockedKey = "lgPrefsLockedForCrashDebug"

private func prefsLockedForCrashDebug() -> Bool {
    UserDefaults(suiteName: kSuite)?.bool(forKey: kPrefsLockedKey) ?? false
}

private func pref(_ key: String, default def: Bool = true) -> Bool {
    if prefsLockedForCrashDebug() { return false }
    guard let obj = UserDefaults(suiteName: kSuite)?.object(forKey: key) else { return def }
    if let b = obj as? Bool { return b }
    if let n = obj as? NSNumber { return n.boolValue }
    return def
}

private func isEnabled() -> Bool {
    if prefsLockedForCrashDebug() { return false }
    guard let d = UserDefaults(suiteName: kSuite) else { return true }
    if d.object(forKey: "Enabled") != nil { return d.bool(forKey: "Enabled") }
    if d.object(forKey: "enabled") != nil { return d.bool(forKey: "enabled") }
    return true
}
private func isDockEnabled()   -> Bool { isEnabled() && pref("dockEnabled") }
private func isFolderEnabled() -> Bool { isEnabled() && pref("folderEnabled") }
private func isSwitchEnabled() -> Bool { isEnabled() && pref("switchEnabled") }
private func isSliderEnabled()        -> Bool { isEnabled() && pref("sliderEnabled") }
private func isNotificationEnabled()  -> Bool { isEnabled() && pref("notificationEnabled") }
private func isMediaPlayerEnabled()   -> Bool { isEnabled() && pref("mediaPlayerEnabled") }
private func isControlCenterEnabled()    -> Bool { isEnabled() && pref("controlCenterEnabled") }
private func isSearchBarEnabled()          -> Bool { isEnabled() && pref("searchBarEnabled") }
private func isLibrarySuggestionsEnabled() -> Bool { isEnabled() && pref("librarySuggestionsEnabled") }
private func isLibraryPodEnabled()         -> Bool { isEnabled() && pref("libraryPodEnabled") }
private func isSpotlightSearchEnabled()    -> Bool { isEnabled() && pref("spotlightSearchEnabled") }
private func isQuickActionEnabled()        -> Bool { isEnabled() && pref("quickActionEnabled") }
private func isContextMenuEnabled()        -> Bool { isEnabled() && pref("contextMenuEnabled") }
private func isKnockoutBackdropEnabled()   -> Bool { isEnabled() && pref("knockoutBackdropEnabled") }
private func isBannerEnabled()             -> Bool { isEnabled() && pref("bannerEnabled") }
private func isWidgetEnabled()             -> Bool { isEnabled() && pref("widgetEnabled") }

// MARK: - Associated object keys
private enum K {
    static var gv: UInt8 = 0   // dock glass view
    static var fi: UInt8 = 0   // folder icon glass view
    static var fo: UInt8 = 0   // open folder background glass
    static var nc: UInt8 = 0   // notification cell glass view
    static var mp: UInt8 = 0   // media player glass view
    static var sb: UInt8 = 0   // search bar glass view
    static var ls: UInt8 = 0   // App Library suggestions glass view
    static var ss: UInt8 = 0   // Spotlight search pill glass view
    static var qa: UInt8 = 0   // Lock screen quick action glass view
    static var dkb: UInt8 = 0  // Dimming knockout replacement glass (keyed on knockout view)
    static var adg: UInt8 = 0  // Alert dialog container glass (no knockout fallback)
    static var adt: UInt8 = 0  // Last applied alert-glass dark-mode flag
    static var bn: UInt8 = 0   // Banner notification glass view
    static var cc: UInt8 = 0   // Control Center module glass view
    static var ccRetry: UInt8 = 0   // CC module glass retry scheduler
    static var al: UInt8 = 0   // App Library pod glass view
    static var cm: UInt8 = 0   // Context menu (long-press) glass view
    static var sp: UInt8 = 0   // Search/page-dots pill glass view
    static var nbg: UInt8 = 0  // Settings nav bar button background glass
}

private func storedGlassView(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.gv) as? LiquidGlassEffectView
}
private func storeGlassView(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.gv, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

// MARK: - Helpers

// Check if a view has any icon-related descendants (we must never hide those)
private func hasIconDescendants(_ view: UIView) -> Bool {
    for sub in view.subviews {
        let n = String(describing: type(of: sub))
        if n.contains("Icon") || n.contains("SBApp") { return true }
        if hasIconDescendants(sub) { return true }
    }
    return false
}

// Recursively strip all dock material while preserving icon views.
// Rule: if a subview has icon descendants → clear its bg and recurse.
//        if it has no icon descendants → hide it entirely (it's pure decoration).
private func hideBackgrounds(in view: UIView) {
    for sub in view.subviews {
        let n = String(describing: type(of: sub))

        // Never touch icon views themselves
        if n.contains("Icon") || n.contains("Badge") || n.contains("SBApp") { continue }

        // UIVisualEffectView: nulling the effect makes it fully transparent
        if let vev = sub as? UIVisualEffectView {
            vev.effect = nil
            vev.backgroundColor = .clear
            continue
        }

        if hasIconDescendants(sub) {
            // Container holds icons — clear its fill but keep it visible and recurse
            sub.backgroundColor = .clear
            sub.layer.backgroundColor = UIColor.clear.cgColor
            hideBackgrounds(in: sub)
        } else {
            // Pure decoration (blur, highlight, shadow, background pill, etc.) — hide it
            sub.isHidden = true
        }
    }
}

private func showBackgrounds(in view: UIView) {
    for sub in view.subviews {
        sub.isHidden = false
        if let vev = sub as? UIVisualEffectView {
            vev.effect = UIBlurEffect(style: .systemMaterial)
        }
        showBackgrounds(in: sub)
    }
}

// Find the frame for the glass pill — use the dock's first background subview frame,
// or fall back to the dock bounds inset to match typical dock pill proportions.
private func backgroundPillFrame(in view: UIView) -> CGRect? {
    // Look for a platter/background subview that was previously visible
    for sub in view.subviews {
        let n = String(describing: type(of: sub))
        if n.contains("Platter") || n.contains("Background") {
            // Use its frame even though we've hidden it — the frame is still valid
            return sub.frame
        }
    }
    return nil
}

// MARK: - App Library category pod (SBHLibraryCategoryPodBackgroundView host)
// Replaces the custom Metal LGAL renderer with the same LiquidGlassEffectView(.clear)
// used by home screen folder icons and the App Library search bar — identical glass.

private func storedLibraryPodGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.al) as? LiquidGlassEffectView
}
private func storeLibraryPodGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.al, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@_silgen_name("LGApplyToLibraryPod")
public func applyToLibraryPod(_ host: UIView) {
    guard isLibraryPodEnabled(), host.bounds.width > 0 else { return }

    let r = host.layer.cornerRadius > 1 ? host.layer.cornerRadius : 20

    // Fast path — glass already installed; sync frame, keep clear.
    if let gv = storedLibraryPodGlass(for: host) {
        gv.frame = host.bounds
        gv.layer.cornerRadius = r
        if host.subviews.first !== gv { host.sendSubviewToBack(gv) }
        host.backgroundColor = .clear
        host.layer.backgroundColor = UIColor.clear.cgColor
        for sub in host.subviews {
            if sub === gv { continue }
            let n = String(describing: type(of: sub))
            if n.contains("Background") || n.contains("Backdrop") || n.contains("Material") {
                sub.isHidden = true
                sub.layer.opacity = 0
            }
            if let vev = sub as? UIVisualEffectView {
                vev.effect = nil
                vev.isHidden = true
            }
        }
        return
    }

    host.backgroundColor = .clear
    host.layer.backgroundColor = UIColor.clear.cgColor

    // Hide the stock background view (SBHLibraryCategoryPodBackgroundView) that draws
    // the grey rounded-rect. It's a direct subview of `host`.
    for sub in host.subviews {
        let n = String(describing: type(of: sub))
        if n.contains("Background") || n.contains("Backdrop") || n.contains("Material") {
            sub.isHidden = true
            sub.layer.opacity = 0
        }
        if let vev = sub as? UIVisualEffectView {
            vev.effect = nil
            vev.isHidden = true
        }
    }
    killBackdropLayers(in: host.layer)

    let effect = LiquidGlassEffect(style: .clear, isNative: false)
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = host.bounds
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = r
    gv.layer.cornerCurve  = .continuous
    gv.clipsToBounds = false
    gv.alpha = 0  // hidden until snapshot is ready — prevents black flash on App Library open
    host.insertSubview(gv, at: 0)
    storeLibraryPodGlass(gv, for: host)

    GlassDisplayLink.shared.register(host: host, glass: gv, fallbackR: r)

    // Pre-warm only during transition suspension (App Library opening). During
    // normal scrolling/reuse, synchronous captureBackground() per pod is expensive
    // and causes visible hitching.
    let isInSuspensionWindow = CACurrentMediaTime() < LiquidGlassRenderer.shared.capturesSuspendedUntil
    if isInSuspensionWindow {
        gv.captureBackground()
        UIView.animate(withDuration: 0.25, delay: 0.05, options: .curveEaseOut) {
            gv.alpha = 1
        }
    } else {
        gv.alpha = 1
    }
}

@_silgen_name("LGRemoveLibraryPodGlass")
public func removeLibraryPodGlass(_ host: UIView) {
    if let gv = storedLibraryPodGlass(for: host) {
        GlassDisplayLink.shared.unregister(host: host)
        gv.removeFromSuperview()
        objc_setAssociatedObject(host, &K.al, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

// MARK: - Search + page-dots pill (SBFolderScrollAccessoryView / MTMaterialView)
// The rounded pill at the bottom of the home screen containing the search bar and page dots.

private func storedSearchPillGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.sp) as? LiquidGlassEffectView
}
private func storeSearchPillGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.sp, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@_silgen_name("LGApplyToSearchPill")
public func applyToSearchPill(_ materialView: UIView) {
    guard isEnabled() else { return }
    guard let parent = materialView.superview else { return }
    guard materialView.bounds.width > 0, materialView.bounds.height > 0 else { return }

    // Use the MTMaterialView's own frame and cornerRadius — it is exactly the pill shape.
    let pillFrame = materialView.frame
    let r = materialView.layer.cornerRadius > 1
        ? materialView.layer.cornerRadius
        : pillFrame.height / 2

    // Fast path — glass already installed; sync to latest frame in case pill moved.
    if let gv = storedSearchPillGlass(for: materialView) {
        gv.frame = pillFrame
        gv.layer.cornerRadius = r
        return
    }

    // Inject glass as a SIBLING of MTMaterialView at the same z-index.
    // This completely avoids fighting MTMaterialView's CABackdropLayer
    // .clear: high-quality glass blur without the frosted white/grey tint.
    // Quality now matches .regular (scaleCoefficient=0.5, blurRadius=0.5) but no fill tint.
    let effect = LiquidGlassEffect(style: .clear, isNative: false)
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = pillFrame
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = r
    gv.layer.cornerCurve = .continuous
    gv.clipsToBounds = false
    gv.alpha = 0  // hidden until snapshot is ready — prevents black flash
    if let idx = parent.subviews.firstIndex(of: materialView) {
        parent.insertSubview(gv, at: idx)
    } else {
        parent.addSubview(gv)
    }
    storeSearchPillGlass(gv, for: materialView)

    DispatchQueue.main.async {
        // Pre-capture before first visible frame so there's no "readjustment" flash.
        gv.captureBackground()
        UIView.animate(withDuration: 0.2) { gv.alpha = 1.0 }
    }
}

// MARK: - Context menu glass (long-press on any app icon)
// Hooks into the UIVisualEffectView that iOS renders inside _UIContextMenuListView.
// We nil the system blur and inject LiquidGlassEffectView(.clear) instead — same
// glass style as folder icons and the search bar.

/// Light/dark adaptive tint for context menus and alert dialog glass (50% more opaque than base).
private func overlayGlassAdaptiveTint(isDark: Bool) -> UIColor {
    let baseAlpha: CGFloat = isDark ? 0.85 : 0.82
    let alpha = min(1.0, baseAlpha * 1.5)
    return UIColor(white: isDark ? 0.08 : 1.00, alpha: alpha)
}

private func storedContextMenuGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.cm) as? LiquidGlassEffectView
}
private func storeContextMenuGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.cm, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@_silgen_name("LGApplyToContextMenu")
public func applyToContextMenu(_ effectView: UIView) {
    guard isContextMenuEnabled() else { return }
    guard let vev = effectView as? UIVisualEffectView else { return }
    let contentView = vev.contentView
    guard contentView.bounds.width > 10, contentView.bounds.height > 10 else { return }

    let r = effectView.layer.cornerRadius > 1 ? effectView.layer.cornerRadius : 22

    // Fast path — glass already installed; just sync frame/radius.
    if let gv = storedContextMenuGlass(for: effectView) {
        gv.frame = contentView.bounds
        gv.layer.cornerRadius = r
        vev.effect = nil
        vev.backgroundColor = .clear
        effectView.layer.backgroundColor = UIColor.clear.cgColor
        return
    }

    // Strip the system blur so we can render our own glass underneath the content.
    vev.effect = nil
    vev.backgroundColor = .clear
    effectView.layer.backgroundColor = UIColor.clear.cgColor

    // Dark mode → dark grey glass. Light mode → white glass. Both heavier than notification.
    let isDark = effectView.traitCollection.userInterfaceStyle == .dark
                 || UIScreen.main.traitCollection.userInterfaceStyle == .dark
    let effect = LiquidGlassEffect(style: .regular, isNative: false)
    effect.blurMultiplier = GlassDisplayPreferences.overlayBlurMultiplier
    effect.tintColor = overlayGlassAdaptiveTint(isDark: isDark)

    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = contentView.bounds
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = r
    gv.layer.cornerCurve  = .continuous
    gv.clipsToBounds = true
    contentView.insertSubview(gv, at: 0)
    storeContextMenuGlass(gv, for: effectView)
}

@_silgen_name("LGRemoveContextMenuGlass")
public func removeContextMenuGlass(_ effectView: UIView) {
    if let gv = storedContextMenuGlass(for: effectView) {
        gv.removeFromSuperview()
        objc_setAssociatedObject(effectView, &K.cm, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

// MARK: - App Library Suggestions row (_SBHLibrarySuggestionsView)
// The full-width rounded card at the top of App Library showing 4 recent/suggested apps.

private func storedSuggestionsGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.ls) as? LiquidGlassEffectView
}
private func storeSuggestionsGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.ls, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@_silgen_name("LGApplyToLibrarySuggestions")
public func applyToLibrarySuggestions(_ view: UIView) {
    guard isLibrarySuggestionsEnabled(), view.bounds.width > 0 else { return }

    // Fast path — GlassDisplayLink owns frame + cornerRadius sync at display refresh rate.
    if let gv = storedSuggestionsGlass(for: view) {
        if gv.isHidden { gv.isHidden = false }
        if view.subviews.first !== gv { view.sendSubviewToBack(gv) }
        view.backgroundColor = .clear
        view.layer.backgroundColor = UIColor.clear.cgColor
        for sub in view.subviews {
            if sub === gv { continue }
            if sub is UIImageView || sub is UILabel { continue }
            if let vev = sub as? UIVisualEffectView { vev.effect = nil; vev.backgroundColor = .clear; continue }
            let n = String(describing: type(of: sub))
            if n.contains("Background") || n.contains("Backdrop") || n.contains("Shadow") ||
               n.contains("Material") || n.contains("Tint") {
                sub.isHidden = true
            }
        }
        return
    }

    // ---- First-time setup (runs once per view instance) ----
    let fallbackR = view.bounds.height * 0.18
    let r = view.layer.cornerRadius > 0.5 ? view.layer.cornerRadius : fallbackR

    view.backgroundColor = .clear
    view.layer.backgroundColor = UIColor.clear.cgColor

    let effect = LiquidGlassEffect(style: .clear, isNative: false)
    effect.tintColor = UIColor.white.withAlphaComponent(DeviceCapability.tintAlpha)
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = view.bounds
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = r
    gv.layer.cornerCurve = .continuous
    gv.clipsToBounds = true
    view.insertSubview(gv, at: 0)
    storeSuggestionsGlass(gv, for: view)
    let glassLayer = gv.layer

    // Strip background fill layers — once only, never repeated
    for sublayer in view.layer.sublayers ?? [] {
        if sublayer === glassLayer { continue }
        if sublayer.contents != nil { continue }
        guard let bg = sublayer.backgroundColor, bg.alpha > 0.01 else { continue }
        sublayer.isHidden = true
        sublayer.backgroundColor = UIColor.clear.cgColor
    }
    killBackdropLayers(in: view.layer, skipping: glassLayer)

    for sub in view.subviews {
        if sub === gv { continue }
        if sub is UIImageView || sub is UILabel { continue }
        if let vev = sub as? UIVisualEffectView { vev.effect = nil; vev.backgroundColor = .clear; continue }
        let n = String(describing: type(of: sub))
        if n.contains("Background") || n.contains("Backdrop") || n.contains("Shadow") ||
           n.contains("Material") || n.contains("Tint") {
            sub.isHidden = true
            killBackdropLayers(in: sub.layer)
        }
    }

    // Hand off to the display link for frame + corner sync while on-screen
    GlassDisplayLink.shared.register(host: view, glass: gv, fallbackR: fallbackR)
}

// MARK: - Home screen Spotlight search pill (SBSearchBarTextField)

private func storedSpotlightSearchGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.ss) as? LiquidGlassEffectView
}
private func storeSpotlightSearchGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.ss, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@_silgen_name("LGApplyToSpotlightSearch")
public func applyToSpotlightSearch(_ textField: UIView) {
    guard isSpotlightSearchEnabled(), textField.bounds.width > 0 else { return }
    guard let parent = textField.superview else { return }

    let frameInParent = textField.convert(textField.bounds, to: parent)
    guard frameInParent.width > 0 else { return }
    let cornerR: CGFloat = frameInParent.height / 2

    // Sync existing glass — cheap path, runs every layoutSubviews
    if let gv = storedSpotlightSearchGlass(for: textField) {
        if gv.frame != frameInParent { gv.frame = frameInParent }
        if gv.layer.cornerRadius != cornerR { gv.layer.cornerRadius = cornerR }
        return
    }

    // ---- First-time setup only from here ----
    textField.backgroundColor = .clear
    textField.layer.backgroundColor = UIColor.clear.cgColor
    if let tf = textField as? UITextField {
        tf.borderStyle = .none
        tf.background = nil
    }
    for sub in textField.subviews {
        guard !(sub is LiquidGlassEffectView) else { continue }
        let n = String(describing: type(of: sub))
        if n.contains("Background") || n.contains("Backdrop") || n.contains("Material") ||
           n.contains("RoundedRect") || n.contains("Border") || n.contains("SearchField") {
            sub.isHidden = true
            sub.alpha = 0
            killBackdropLayers(in: sub.layer)
        }
        if let vev = sub as? UIVisualEffectView { 
            vev.effect = nil
            vev.backgroundColor = .clear 
            vev.isHidden = true
        }
    }

    // Defer creation so the view hierarchy is fully laid out before we snapshot the frame.
    DispatchQueue.main.async {
        guard textField.window != nil,
              let parent = textField.superview,
              storedSpotlightSearchGlass(for: textField) == nil else { return }
        let frame = textField.convert(textField.bounds, to: parent)
        guard frame.width > 0 else { return }
        let cornerR: CGFloat = frame.height / 2
        let isDark = textField.traitCollection.userInterfaceStyle == .dark || UIScreen.main.traitCollection.userInterfaceStyle == .dark
        let effect = LiquidGlassEffect(style: .clear, isNative: false)
        if DeviceCapability.isLowEnd {
            // "Crystal Clear" transparency: no blur, 3% tint.
            let alpha: CGFloat = 0.03
            let tint = isDark ? UIColor(white: 0.28, alpha: 1.0) : (effect.tintColor ?? .white)
            effect.tintColor = tint.withAlphaComponent(alpha)
        }
        let gv = LiquidGlassEffectView(effect: effect)
        gv.frame = frame
        gv.isUserInteractionEnabled = false
        gv.layer.cornerRadius = cornerR
        gv.layer.cornerCurve = .continuous
        gv.clipsToBounds = false
        if let idx = parent.subviews.firstIndex(of: textField) {
            parent.insertSubview(gv, at: idx)
        } else {
            parent.addSubview(gv)
        }
        storeSpotlightSearchGlass(gv, for: textField)
    }
}

// MARK: - Search bar (App Library SBHSearchTextField)

private func storedSearchBarGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.sb) as? LiquidGlassEffectView
}
private func storeSearchBarGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.sb, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@_silgen_name("LGApplyToSearchBar")
public func applyToSearchBar(_ textField: UIView) {
    guard isSearchBarEnabled(), textField.bounds.width > 0 else { return }
    guard let parent = textField.superview else { return }

    // Convert text field frame to parent coords
    let frameInParent = textField.convert(textField.bounds, to: parent)
    guard frameInParent.width > 0 else { return }
    let cornerR: CGFloat = frameInParent.height / 2

    // Sync existing glass — cheap path, runs every layoutSubviews
    if let gv = storedSearchBarGlass(for: textField) {
        if gv.frame != frameInParent { gv.frame = frameInParent }
        if gv.layer.cornerRadius != cornerR { gv.layer.cornerRadius = cornerR }
        return
    }

    // ---- First-time setup only from here ----
    // Make the UITextField itself fully transparent
    textField.backgroundColor = .clear
    textField.layer.backgroundColor = UIColor.clear.cgColor
    if let tf = textField as? UITextField {
        tf.borderStyle = .none
        tf.background = nil
    }
    // Hide background-drawing subviews (once)
    for sub in textField.subviews {
        guard !(sub is LiquidGlassEffectView) else { continue }
        let n = String(describing: type(of: sub))
        if n.contains("Background") || n.contains("Backdrop") || n.contains("RoundedRect") || 
           n.contains("Border") || n.contains("SearchField") {
            sub.isHidden = true
            sub.alpha = 0
            killBackdropLayers(in: sub.layer)
        }
        if let vev = sub as? UIVisualEffectView { 
            vev.effect = nil
            vev.backgroundColor = .clear 
            vev.isHidden = true
        }
    }

    // Defer initial glass creation to the next run loop so the view hierarchy
    // is fully laid out — prevents the glass appearing at the wrong (pre-layout)
    // position during respring and then jumping to the correct place.
    DispatchQueue.main.async {
        guard textField.window != nil,
              let parent = textField.superview,
              storedSearchBarGlass(for: textField) == nil else { return }
        let frame = textField.convert(textField.bounds, to: parent)
        guard frame.width > 0 else { return }
        let cornerR: CGFloat = frame.height / 2
        let isDark = textField.traitCollection.userInterfaceStyle == .dark || UIScreen.main.traitCollection.userInterfaceStyle == .dark
        let effect = LiquidGlassEffect(style: .clear, isNative: false)
        if DeviceCapability.isLowEnd {
            // "Crystal Clear" transparency: no blur, 3% tint.
            let alpha: CGFloat = 0.03
            let tint = isDark ? UIColor(white: 0.28, alpha: 1.0) : (effect.tintColor ?? .white)
            effect.tintColor = tint.withAlphaComponent(alpha)
        }
        let gv = LiquidGlassEffectView(effect: effect)
        gv.frame = frame
        gv.isUserInteractionEnabled = false
        gv.layer.cornerRadius = cornerR
        gv.layer.cornerCurve = .continuous
        gv.clipsToBounds = false
        if let idx = parent.subviews.firstIndex(of: textField) {
            parent.insertSubview(gv, at: idx)
        } else {
            parent.addSubview(gv)
        }
        storeSearchBarGlass(gv, for: textField)
    }
}

// MARK: - Dock

@_silgen_name("LGApplyToDockView")
public func applyToDockView(_ dock: UIView) {
    let on = isDockEnabled()

    // Always re-strip the material — iOS restores it between layoutSubviews calls
    if on {
        hideBackgrounds(in: dock)
        dock.backgroundColor = .clear
    }

    // Already set up — just sync frame
    if let gv = storedGlassView(for: dock) {
        if on {
            gv.isHidden = false
            let syncInset = dock.bounds.insetBy(dx: 10, dy: 6)
            let maxPillHeight: CGFloat = 83
            let syncFallback = syncInset.height > maxPillHeight
                ? CGRect(x: syncInset.minX, y: syncInset.minY, width: syncInset.width, height: maxPillHeight)
                : syncInset
            let pillFrame = backgroundPillFrame(in: dock) ?? syncFallback
            gv.frame = pillFrame
            gv.layer.cornerRadius = min(pillFrame.height, pillFrame.width) * 0.35
        } else {
            gv.isHidden = true
            showBackgrounds(in: dock)
        }
        return
    }

    guard on, dock.bounds.width > 0 else { return }

    // Use the background pill's frame if found, otherwise inset the full bounds.
    // Cap fallback height to ~83 pt so the glass pill isn't over-tall on iPhone X/newer
    // where SBDockView includes extra padding below the pill for the home indicator.
    let fallbackFrame: CGRect = {
        let inset = dock.bounds.insetBy(dx: 10, dy: 6)
        let maxPillHeight: CGFloat = 83
        if inset.height > maxPillHeight {
            let clipped = CGRect(x: inset.minX, y: inset.minY,
                                 width: inset.width, height: maxPillHeight)
            return clipped
        }
        return inset
    }()
    let pillFrame = backgroundPillFrame(in: dock) ?? fallbackFrame

    // .clear: high-quality glass blur without the frosted white/grey tint.
    // Quality now matches .regular (scaleCoefficient=0.5, blurRadius=0.5) but no fill tint.
    let effect = LiquidGlassEffect(style: .clear, isNative: false)
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = pillFrame
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = min(pillFrame.height, pillFrame.width) * 0.44
    gv.layer.cornerCurve  = .continuous
    gv.clipsToBounds = false
    dock.insertSubview(gv, at: 0)
    storeGlassView(gv, for: dock)
}

// MARK: - Lock screen helpers

private func isLockScreenWindow(_ window: UIWindow?) -> Bool {
    guard let window else { return false }
    let winName = String(describing: type(of: window))
    return winName.contains("CoverSheet") || winName.contains("LockScreen")
}

private func lockScreenGlassCornerRadius(for view: UIView) -> CGFloat {
    if view.layer.cornerRadius > 0.5 { return view.layer.cornerRadius }
    let side = min(view.bounds.width, view.bounds.height)
    return side > 0 ? side * 0.5 : 0
}

/// True only for the full-window scrim — not alert cards (which are often >45% screen width).
private func isFullScreenDimmingKnockout(_ view: UIView) -> Bool {
    let size = view.bounds.size
    guard size.width > 0, size.height > 0 else { return false }
    if let window = view.window {
        let screen = window.bounds.size
        let w = size.width / screen.width
        let h = size.height / screen.height
        return w > 0.85 && h > 0.85
    }
    return size.width > 300 && size.height > 500
}

private let alertDialogGlassCornerRadius: CGFloat = 30
/// Horizontal + bottom bleed past the dialog card; top stays flush with the dialog.
private let alertDialogGlassContentInset: CGFloat = 10
private let alertActionSpacing: CGFloat = 10

private func alertDialogGlassExpandedBounds(_ containerBounds: CGRect) -> CGRect {
    let inset = alertDialogGlassContentInset
    return CGRect(
        x: containerBounds.minX - inset,
        y: containerBounds.minY,
        width: containerBounds.width + inset * 2,
        height: containerBounds.height + inset
    )
}

private enum AlertLayoutGuard {
    private static let chromeKey = "LGAlertChrome"
    private static let actionsKey = "LGAlertActions"

    static var isApplyingChrome: Bool {
        get { Thread.current.threadDictionary[chromeKey] as? Bool ?? false }
        set { Thread.current.threadDictionary[chromeKey] = newValue }
    }

    static var isLayoutingActions: Bool {
        get { Thread.current.threadDictionary[actionsKey] as? Bool ?? false }
        set { Thread.current.threadDictionary[actionsKey] = newValue }
    }
}

private func isAlertPresentationKnockout(_ knockout: UIView) -> Bool {
    var v: UIView? = knockout.superview
    while let view = v {
        let name = String(describing: type(of: view))
        if name.contains("AlertController") { return true }
        v = view.superview
    }
    return false
}

/// Alert dialog card knockout (inside an alert, not the full-screen scrim).
private func isAlertDialogKnockout(_ knockout: UIView) -> Bool {
    isAlertPresentationKnockout(knockout) && !isFullScreenDimmingKnockout(knockout)
}

private func isAlertDialogContainer(_ view: UIView) -> Bool {
    let name = String(describing: type(of: view))
    return name.contains("PhoneTVMac") || name == "_UIAlertControllerView"
}

private func storedAlertDialogContainerGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.adg) as? LiquidGlassEffectView
}
private func storeAlertDialogContainerGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.adg, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

private func findKnockoutSubview(in root: UIView) -> UIView? {
    guard let koClass = NSClassFromString("_UIDimmingKnockoutBackdropView") else { return nil }
    var stack = [root]
    while let view = stack.popLast() {
        if view.isKind(of: koClass) { return view }
        stack.append(contentsOf: view.subviews)
    }
    return nil
}

private func stripAlertDialogSystemBlur(in container: UIView) {
    for sub in container.subviews {
        let name = String(describing: type(of: sub))
        if name.contains("Backdrop") || name.contains("Material") || name.contains("VisualEffect") {
            sub.isHidden = true
            sub.alpha = 0
            sub.layer.opacity = 0
            killBackdropLayers(in: sub.layer)
        }
    }
}

private func alertDialogContainerGlassFrame(_ container: UIView, in parent: UIView) -> CGRect {
    let frame = alertDialogGlassExpandedBounds(container.bounds)
    return parent.convert(frame, from: container)
}

private func syncAlertDialogContainerGlass(_ container: UIView) {
    guard isAlertDialogContainer(container), container.bounds.width > 1,
          container.bounds.height > 1, let parent = container.superview else { return }

    if findKnockoutSubview(in: container) != nil { return }

    stripAlertDialogSystemBlur(in: container)
    let frame = alertDialogContainerGlassFrame(container, in: parent)

    if let gv = storedAlertDialogContainerGlass(for: container) {
        if gv.superview !== parent {
            parent.insertSubview(gv, belowSubview: container)
        }
        gv.frame = frame
        applyAlertGlassChrome(to: gv, host: container, cornerRadius: alertDialogGlassCornerRadius)
        parent.bringSubviewToFront(container)
        gv.liquidGlassView?.noteHostBecameVisible()
        return
    }

    let gv = LiquidGlassEffectView(effect: makeAlertDialogGlassEffect(for: container))
    gv.isUserInteractionEnabled = false
    parent.insertSubview(gv, belowSubview: container)
    gv.frame = frame
    applyAlertGlassChrome(to: gv, host: container, cornerRadius: alertDialogGlassCornerRadius)
    storeAlertDialogContainerGlass(gv, for: container)
    parent.bringSubviewToFront(container)
    gv.captureBackground()
}

private func dimmingKnockoutCornerRadius(for view: UIView) -> CGFloat {
    if isAlertDialogKnockout(view) { return alertDialogGlassCornerRadius }
    if isFullScreenDimmingKnockout(view) { return 0 }
    return lockScreenGlassCornerRadius(for: view)
}

private func makeAlertDialogGlassEffect(for host: UIView) -> LiquidGlassEffect {
    let isDark = host.traitCollection.userInterfaceStyle == .dark
        || UIScreen.main.traitCollection.userInterfaceStyle == .dark
    let effect = LiquidGlassEffect(style: .regular, isNative: false)
    effect.blurMultiplier = GlassDisplayPreferences.overlayBlurMultiplier
    effect.tintColor = overlayGlassAdaptiveTint(isDark: isDark)
    return effect
}

private func syncAlertDialogGlassEffect(_ glass: LiquidGlassEffectView, host: UIView) {
    let isDark = host.traitCollection.userInterfaceStyle == .dark
        || UIScreen.main.traitCollection.userInterfaceStyle == .dark
    if let prev = objc_getAssociatedObject(glass, &K.adt) as? Bool, prev == isDark,
       (glass.effect as? LiquidGlassEffect)?.style == .regular,
       glass.liquidGlassView != nil {
        return
    }
    objc_setAssociatedObject(glass, &K.adt, isDark, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    let effect = makeAlertDialogGlassEffect(for: host)
    glass.effect = effect
    glass.liquidGlassView?.removeFromSuperview()
    let lgv = LiquidGlassView(effect.resolvedLiquidGlass())
    glass.liquidGlassView = lgv
}

private func applyAlertGlassChrome(
    to glass: LiquidGlassEffectView,
    host: UIView,
    cornerRadius: CGFloat
) {
    syncAlertDialogGlassEffect(glass, host: host)
    glass.layer.cornerRadius = cornerRadius
    glass.layer.cornerCurve = .continuous
    glass.clipsToBounds = cornerRadius > 0.5
    glass.liquidGlassView?.layer.cornerRadius = cornerRadius
    glass.liquidGlassView?.layer.cornerCurve = .continuous
}

/// Hide the system knockout dimmer entirely — glass lives in the superview instead.
private func completelyHideDimmingKnockout(_ knockout: UIView) {
    knockout.isHidden = true
    knockout.alpha = 0
    knockout.layer.opacity = 0
    knockout.isOpaque = false
    knockout.isUserInteractionEnabled = false
    knockout.backgroundColor = .clear
    knockout.layer.backgroundColor = UIColor.clear.cgColor
    killBackdropLayers(in: knockout.layer)
    for sub in knockout.subviews {
        sub.isHidden = true
        sub.alpha = 0
        sub.layer.opacity = 0
        killBackdropLayers(in: sub.layer)
    }
}

private func knockoutReplacementFrame(
    _ knockout: UIView,
    in parent: UIView,
    alertCardStyle: Bool
) -> CGRect {
    let base: CGRect
    if knockout.bounds.width > 0, knockout.bounds.height > 0 {
        base = parent.convert(knockout.bounds, from: knockout)
    } else {
        base = knockout.frame
    }
    guard alertCardStyle else { return base }
    let inset = alertDialogGlassContentInset
    return CGRect(
        x: base.minX - inset,
        y: base.minY,
        width: base.width + inset * 2,
        height: base.height + inset
    )
}

private func syncKnockoutReplacementGlass(
    _ glass: LiquidGlassEffectView,
    knockout: UIView,
    in parent: UIView,
    cornerRadius: CGFloat,
    alertCardStyle: Bool
) {
    if glass.superview === knockout {
        glass.removeFromSuperview()
    }
    if glass.superview !== parent {
        if let idx = parent.subviews.firstIndex(of: knockout) {
            parent.insertSubview(glass, at: idx)
        } else {
            parent.insertSubview(glass, belowSubview: knockout)
        }
    }
    glass.frame = knockoutReplacementFrame(knockout, in: parent, alertCardStyle: alertCardStyle)
    if alertCardStyle {
        applyAlertGlassChrome(to: glass, host: knockout, cornerRadius: cornerRadius)
    } else {
        glass.layer.cornerRadius = cornerRadius
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = cornerRadius > 0.5
        glass.liquidGlassView?.layer.cornerRadius = cornerRadius
        glass.liquidGlassView?.layer.cornerCurve = .continuous
    }

    let subs = parent.subviews
    if let koIdx = subs.firstIndex(of: knockout) {
        for i in (koIdx + 1)..<subs.count {
            let sub = subs[i]
            if sub !== glass { parent.bringSubviewToFront(sub) }
        }
    }
}

// MARK: - Settings navigation bar button backgrounds (back circle + action pills)

private func isSettingsNavButtonGlassEnabled() -> Bool {
    isEnabled() && pref("pageBackButtonEnabled")
}

private func storedSettingsNavButtonGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.nbg) as? LiquidGlassEffectView
}

private func storeSettingsNavButtonGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.nbg, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@_silgen_name("LGApplyGlassToSettingsNavButtonBackground")
public func applyGlassToSettingsNavButtonBackground(_ background: UIView) {
    guard isSettingsNavButtonGlassEnabled(), background.bounds.width > 0, background.bounds.height > 0 else { return }

    let cornerR = background.layer.cornerRadius
    let fallbackR = cornerR > 0.5 ? cornerR : background.bounds.height * 0.5

    if let gv = storedSettingsNavButtonGlass(for: background) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gv.frame = background.bounds
        gv.layer.cornerRadius = cornerR
        if #available(iOS 13.0, *) {
            gv.layer.cornerCurve = background.layer.cornerCurve
        }
        background.insertSubview(gv, at: 0)
        GlassDisplayLink.shared.register(host: background, glass: gv, fallbackR: fallbackR,
                                         continuousBackgroundCapture: true)
        CATransaction.commit()
        return
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let effect = LiquidGlassEffect(style: .clear, isNative: false)
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = background.bounds
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = cornerR
    if #available(iOS 13.0, *) {
        gv.layer.cornerCurve = background.layer.cornerCurve
    }
    gv.clipsToBounds = true
    background.insertSubview(gv, at: 0)
    storeSettingsNavButtonGlass(gv, for: background)
    GlassDisplayLink.shared.register(host: background, glass: gv, fallbackR: fallbackR,
                                     continuousBackgroundCapture: true)
    gv.captureBackground()
    gv.liquidGlassView?.markCaptureNeeded()
    CATransaction.commit()
}

@_silgen_name("LGRemoveGlassFromSettingsNavButtonBackground")
public func removeGlassFromSettingsNavButtonBackground(_ background: UIView) {
    GlassDisplayLink.shared.unregister(host: background)
    if let gv = storedSettingsNavButtonGlass(for: background) {
        gv.removeFromSuperview()
    }
    objc_setAssociatedObject(background, &K.nbg, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

// MARK: - Lock screen quick action buttons (flashlight / camera)

private func storedQuickActionGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.qa) as? LiquidGlassEffectView
}
private func storeQuickActionGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.qa, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@_silgen_name("LGApplyToLockQuickAction")
public func applyToLockQuickAction(_ btn: UIView) {
    guard isQuickActionEnabled(), btn.bounds.width > 0 else { return }

    // Fast path — glass already installed; sync frame + keep clear.
    if let gv = storedQuickActionGlass(for: btn) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        btn.backgroundColor = .clear
        btn.layer.backgroundColor = UIColor.clear.cgColor
        gv.frame = btn.bounds
        gv.layer.cornerRadius = btn.bounds.width * 0.5
        // Re-hide every non-glass subview every pass — iOS restores them.
        // Skip UIImageViews so the icon stays visible.
        for sub in btn.subviews where sub !== gv && !(sub is UIImageView) {
            sub.isHidden = true
            sub.alpha = 0
            sub.layer.opacity = 0
            killBackdropLayers(in: sub.layer)
        }
        // Ensure icon image views remain visible and on top.
        for sub in btn.subviews where sub is UIImageView {
            sub.isHidden = false
            sub.alpha = 1
            sub.layer.opacity = 1
            btn.bringSubviewToFront(sub)
        }
        // Kill any plain fill sublayers (not our metal layer).
        for sublayer in btn.layer.sublayers ?? [] {
            if sublayer === gv.layer { continue }
            if sublayer.contents != nil { continue }
            sublayer.backgroundColor = UIColor.clear.cgColor
            sublayer.opacity = 0
        }
        CATransaction.commit()
        return
    }

    // ---- First-time setup ----
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    // Aggressively clear everything on the button view.
    btn.backgroundColor = .clear
    btn.layer.backgroundColor = UIColor.clear.cgColor
    // Hide ALL subviews — the only things inside a quick action button are the
    // material circle and the icon image view. The icon is a UIImageView so we
    // re-show it after inserting the glass below.
    for sub in btn.subviews {
        sub.isHidden = true
        sub.alpha = 0
        sub.layer.opacity = 0
        killBackdropLayers(in: sub.layer)
    }
    // Kill fill sublayers.
    for sublayer in btn.layer.sublayers ?? [] {
        if sublayer.contents != nil { continue }
        sublayer.backgroundColor = UIColor.clear.cgColor
        sublayer.opacity = 0
    }
    killBackdropLayers(in: btn.layer)

    let effect = LiquidGlassEffect(style: .clear, isNative: false)
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = btn.bounds
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = btn.bounds.width * 0.5
    gv.layer.cornerCurve  = .continuous
    gv.clipsToBounds = false
    btn.insertSubview(gv, at: 0)
    storeQuickActionGlass(gv, for: btn)

    // Bring icon views back to front so they render above glass.
    for sub in btn.subviews where sub !== gv {
        if sub is UIImageView {
            sub.isHidden = false
            sub.alpha = 1
            sub.layer.opacity = 1
            btn.bringSubviewToFront(sub)
        }
    }

    CATransaction.commit()
}

// MARK: - Dimming knockout backdrop (alerts, sheets, lock-screen quick actions)

private func storedDimmingKnockoutGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.dkb) as? LiquidGlassEffectView
}
private func storeDimmingKnockoutGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.dkb, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@_silgen_name("LGApplyDimmingKnockoutInHierarchy")
public func applyDimmingKnockoutInHierarchy(_ root: UIView) {
    guard isKnockoutBackdropEnabled() else { return }
    guard let koClass = NSClassFromString("_UIDimmingKnockoutBackdropView") else { return }
    var stack = [root]
    while let view = stack.popLast() {
        if view.isKind(of: koClass) {
            applyToDimmingKnockoutBackdrop(view)
            continue
        }
        stack.append(contentsOf: view.subviews)
    }
}

private func alertActionFillColor(for host: UIView) -> UIColor {
    let isDark = host.traitCollection.userInterfaceStyle == .dark
        || UIScreen.main.traitCollection.userInterfaceStyle == .dark
    return isDark
        ? UIColor(white: 0.28, alpha: 0.68)
        : UIColor(white: 0.74, alpha: 0.62)
}

/// Title label on `_UIAlertControllerActionView` (`_label` ivar), with hierarchy fallback.
private func alertActionTitleLabel(in action: UIView) -> UILabel? {
    let obj = action as NSObject
    if obj.responds(to: Selector(("label"))), let label = obj.value(forKey: "label") as? UILabel {
        return label
    }
    for intermediate in action.subviews {
        let name = String(describing: type(of: intermediate))
        if name.contains("Backdrop") || name.contains("Material") || name.contains("VisualEffect") {
            continue
        }
        for sub in intermediate.subviews {
            if let label = sub as? UILabel { return label }
        }
    }
    return nil
}

private func uiAlertAction(from actionView: UIView) -> NSObject? {
    let obj = actionView as NSObject
    guard obj.responds(to: Selector(("action"))) else { return nil }
    return obj.value(forKey: "action") as? NSObject
}

/// UIKit stores the displayed title color on `UIAlertAction`, not in `UILabel.textColor`.
private func uiAlertActionTitleTextColor(from actionView: UIView) -> UIColor? {
    guard let alertAction = uiAlertAction(from: actionView) else { return nil }
    if alertAction.responds(to: Selector(("_titleTextColor"))) {
        return alertAction.value(forKey: "_titleTextColor") as? UIColor
    }
    if alertAction.responds(to: Selector(("titleTextColor"))) {
        return alertAction.value(forKey: "titleTextColor") as? UIColor
    }
    return nil
}

private let nsColorAttributeKey = NSAttributedString.Key(rawValue: "NSColor")

private func isCatalogLabelColor(_ color: UIColor) -> Bool {
    let desc = String(describing: color)
    return desc.contains("labelColor") || desc.contains("LabelColor")
}

private func isBoldFont(_ font: UIFont) -> Bool {
    if font.fontDescriptor.symbolicTraits.contains(.traitBold) { return true }
    if font.fontName.localizedCaseInsensitiveContains("Bold") { return true }
    let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
    if let weight = traits?[.weight] as? CGFloat, weight >= UIFont.Weight.semibold.rawValue {
        return true
    }
    return false
}

private func isAlertActionLabelBold(_ label: UILabel) -> Bool {
    if let font = label.font, isBoldFont(font) { return true }
    guard let attr = label.attributedText, attr.length > 0 else { return false }
    var bold = false
    attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { value, _, stop in
        if let font = value as? UIFont, isBoldFont(font) {
            bold = true
            stop.pointee = true
        }
    }
    return bold
}

private func fullyOpaqueColor(_ color: UIColor, in traits: UITraitCollection) -> UIColor {
    let resolved = color.resolvedColor(with: traits)
    guard let comps = resolved.cgColor.components, !comps.isEmpty else {
        return resolved.withAlphaComponent(1)
    }
    switch resolved.cgColor.numberOfComponents {
    case 2:
        return UIColor(white: comps[0], alpha: 1)
    case 4:
        return UIColor(red: comps[0], green: comps[1], blue: comps[2], alpha: 1)
    default:
        return resolved.withAlphaComponent(1)
    }
}

private func colorsAreSimilar(_ a: UIColor, _ b: UIColor, tolerance: CGFloat = 0.08) -> Bool {
    var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
    var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
    guard a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa),
          b.getRed(&br, green: &bg, blue: &bb, alpha: &ba) else { return false }
    return abs(ar - br) <= tolerance && abs(ag - bg) <= tolerance && abs(ab - bb) <= tolerance
}

private func isNeutralAccentColor(_ color: UIColor, traits: UITraitCollection) -> Bool {
    if isCatalogLabelColor(color) { return true }
    let resolved = color.resolvedColor(with: traits)
    let labelColor = UIColor.label.resolvedColor(with: traits)
    let secondary = UIColor.secondaryLabel.resolvedColor(with: traits)
    if colorsAreSimilar(resolved, labelColor) || colorsAreSimilar(resolved, secondary) {
        return true
    }
    if colorsAreSimilar(resolved, .white) || colorsAreSimilar(resolved, .black) {
        return true
    }
    return false
}

/// Preferred/default actions: read `UIAlertAction.titleTextColor`; ignore `labelColor` in `attributedText`.
private func alertActionLabelAccentColor(
    action: UIView,
    label: UILabel,
    traits: UITraitCollection
) -> UIColor {
    if let titleColor = uiAlertActionTitleTextColor(from: action), !isNeutralAccentColor(titleColor, traits: traits) {
        return fullyOpaqueColor(titleColor, in: traits)
    }
    if let attr = label.attributedText, attr.length > 0 {
        var accent: UIColor?
        attr.enumerateAttributes(in: NSRange(location: 0, length: attr.length)) { attrs, _, stop in
            for (_, value) in attrs {
                guard let color = value as? UIColor, !isNeutralAccentColor(color, traits: traits) else { continue }
                accent = color
                stop.pointee = true
                return
            }
        }
        if let accent {
            return fullyOpaqueColor(accent, in: traits)
        }
    }
    return fullyOpaqueColor(.systemBlue, in: traits)
}

private func applyWhiteTitleAttributes(to label: UILabel) {
    let white = UIColor.white
    label.textColor = white
    guard let attr = label.attributedText, attr.length > 0 else { return }
    let mutable = NSMutableAttributedString(attributedString: attr)
    let range = NSRange(location: 0, length: mutable.length)
    mutable.enumerateAttributes(in: range) { attrs, subRange, _ in
        for key in attrs.keys where attrs[key] is UIColor {
            mutable.removeAttribute(key, range: subRange)
        }
    }
    mutable.addAttribute(.foregroundColor, value: white, range: range)
    mutable.addAttribute(nsColorAttributeKey, value: white, range: range)
    label.attributedText = mutable
}

private func setAlertDefaultActionTitleWhite(action: UIView, label: UILabel) {
    let white = UIColor.white
    if let alertAction = uiAlertAction(from: action) {
        alertAction.setValue(white, forKey: "titleTextColor")
    }
    applyWhiteTitleAttributes(to: label)
}

private func isInAlertPresentation(_ view: UIView) -> Bool {
    var v: UIView? = view
    while let parent = v {
        let name = String(describing: type(of: parent))
        if name.contains("AlertController") || name.contains("PhoneTVMac") || name.contains("TextEffects") {
            return true
        }
        v = parent.superview
    }
    return false
}

private func isAlertSeparatableSequenceView(_ view: UIView) -> Bool {
    String(describing: type(of: view)).contains("InterfaceActionSeparatableSequence")
}

private func isAlertRepresentationsSequenceView(_ view: UIView) -> Bool {
    String(describing: type(of: view)).contains("InterfaceActionRepresentationsSequence")
}

private func isAlertActionCustomViewRepresentation(_ view: UIView) -> Bool {
    String(describing: type(of: view)).contains("InterfaceActionCustomViewRepresentation")
}

private func alertActionCustomViewRepresentationParent(of action: UIView) -> UIView? {
    var v: UIView? = action.superview
    while let parent = v {
        if isAlertActionCustomViewRepresentation(parent) { return parent }
        v = parent.superview
    }
    return nil
}

private func applyAlertActionPillCornerRadius(_ radius: CGFloat, to view: UIView) {
    view.layer.cornerRadius = radius
    view.layer.cornerCurve = .continuous
    view.layer.masksToBounds = true
    view.clipsToBounds = true
}

private func isAlertActionSequenceContainer(_ view: UIView) -> Bool {
    isAlertSeparatableSequenceView(view) || isAlertRepresentationsSequenceView(view)
}

private func stackHostsAlertActions(_ stack: UIStackView, actionClass: AnyClass) -> Bool {
    func containsAction(_ view: UIView) -> Bool {
        if view.isKind(of: actionClass) { return true }
        for sub in view.subviews where containsAction(sub) { return true }
        return false
    }
    return stack.arrangedSubviews.contains { containsAction($0) }
}

/// UIStackView → _UIInterfaceActionSeparatableSequenceView → _UIInterfaceActionRepresentationsSequenceView
private func isAlertSeparatableSequenceStack(_ stack: UIStackView) -> Bool {
    guard isKnockoutBackdropEnabled() else { return false }
    guard let parent = stack.superview, isAlertSeparatableSequenceView(parent) else { return false }
    guard let actionClass = NSClassFromString("_UIAlertControllerActionView") else { return false }
    return stackHostsAlertActions(stack, actionClass: actionClass)
}

/// Find the alert button stack under Representations and/or Separatable sequence containers.
private func findAlertButtonStack(in root: UIView) -> UIStackView? {
    guard isAlertActionSequenceContainer(root) else { return nil }
    guard let actionClass = NSClassFromString("_UIAlertControllerActionView") else { return nil }
    var walk = [root]
    while let view = walk.popLast() {
        if let stack = view as? UIStackView, isAlertSeparatableSequenceStack(stack) {
            return stack
        }
        walk.append(contentsOf: view.subviews)
    }
    return nil
}

private func enclosingAlertActionButtonStack(for action: UIView) -> UIStackView? {
    var v: UIView? = action.superview
    while let parent = v {
        if let stack = parent as? UIStackView, isAlertSeparatableSequenceStack(stack) {
            return stack
        }
        v = parent.superview
    }
    return nil
}

private func alertActionSequenceContainers(in root: UIView) -> [UIView] {
    var result: [UIView] = []
    var walk = [root]
    while let view = walk.popLast() {
        if isAlertActionSequenceContainer(view) { result.append(view) }
        walk.append(contentsOf: view.subviews)
    }
    return result
}

private func alertControllerActionViews(in stack: UIStackView) -> [UIView] {
    guard let actionClass = NSClassFromString("_UIAlertControllerActionView") else { return [] }
    return stack.arrangedSubviews.filter {
        $0.isKind(of: actionClass) && !$0.isHidden && $0.alpha > 0.01
    }
}

private enum AlertHeightBoostKeys {
    static var constraintBaseline: UInt8 = 0
    static var minHeightConstraint: UInt8 = 0
}

private enum AlertHeightBoostGuard {
    private static let key = "LGAlertHeightBoost"
    static var isActive: Bool {
        get { Thread.current.threadDictionary[key] as? Bool ?? false }
        set { Thread.current.threadDictionary[key] = newValue }
    }
}

/// Extra dialog height for vertical stacks: one `alertActionSpacing` gap per button pair.
private func extraVerticalAlertActionSpacingHeight(for stack: UIStackView) -> CGFloat {
    guard stack.axis == .vertical else { return 0 }
    let count = alertControllerActionViews(in: stack).count
    guard count > 1 else { return 0 }
    return CGFloat(count - 1) * alertActionSpacing
}

/// Stack → SeparatableSequence → RepresentationsSequence → … → InterfaceActionGroup
private func alertActionParentChain(from stack: UIStackView) -> [UIView] {
    var chain: [UIView] = []
    var v: UIView? = stack.superview
    while let parent = v {
        chain.append(parent)
        if isAlertDialogContainer(parent) { break }
        v = parent.superview
    }
    return chain
}

private func alertDialogHeightBoostViews(for stack: UIStackView) -> [UIView] {
    [stack] + alertActionParentChain(from: stack)
}

private let alertControllerNamedHeightConstraintKeys = [
    "heightConstraint",
    "mainActionButtonSequenceViewHeightConstraint",
    "contentViewMaxHeightConstraint",
]

private func alertControllerHeightConstraint(on view: UIView, key: String) -> NSLayoutConstraint? {
    let obj = view as NSObject
    guard obj.responds(to: NSSelectorFromString(key)) else { return nil }
    return obj.value(forKey: key) as? NSLayoutConstraint
}

/// `_UIAlertControllerView` / `PhoneTVMac` owns the card height constraints; may not be a direct stack ancestor.
private func findAlertControllerLayoutView(startingFrom stack: UIStackView) -> UIView? {
    var v: UIView? = stack
    while let view = v {
        if alertControllerHeightConstraint(on: view, key: "heightConstraint") != nil {
            return view
        }
        if isAlertDialogContainer(view) { break }
        v = view.superview
    }
    guard let root = alertDialogHeightBoostViews(for: stack).last else { return nil }
    var walk = [root]
    while let view = walk.popLast() {
        if alertControllerHeightConstraint(on: view, key: "heightConstraint") != nil {
            return view
        }
        walk.append(contentsOf: view.subviews)
    }
    return root
}

private func constraint(_ c: NSLayoutConstraint, involves view: UIView) -> Bool {
    (c.firstItem as? UIView) === view || (c.secondItem as? UIView) === view
}

private func isAdjustableHeightConstraint(_ c: NSLayoutConstraint, for view: UIView) -> Bool {
    guard c.multiplier == 1 else { return false }
    let heightOnView =
        ((c.firstItem as? UIView) === view && c.firstAttribute == .height)
        || ((c.secondItem as? UIView) === view && c.secondAttribute == .height)
    guard heightOnView else { return false }
    switch c.relation {
    case .equal, .greaterThanOrEqual, .lessThanOrEqual: return true
    default: return false
    }
}

private func allConstraintsInvolving(_ view: UIView) -> [NSLayoutConstraint] {
    var result = Array(view.constraints)
    if let superview = view.superview {
        result.append(contentsOf: superview.constraints.filter { constraint($0, involves: view) })
    }
    return result
}

private func requiredHeightToFitChild(_ child: UIView, in parent: UIView) -> CGFloat {
    let childRect = parent.convert(child.bounds, from: child)
    return ceil(childRect.maxY)
}

private func clearAlertSequenceMinimumHeight(on view: UIView) {
    if let existing = objc_getAssociatedObject(view, &AlertHeightBoostKeys.minHeightConstraint) as? NSLayoutConstraint {
        existing.isActive = false
    }
    objc_setAssociatedObject(view, &AlertHeightBoostKeys.minHeightConstraint, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

private func ensureAlertSequenceMinimumHeight(_ minHeight: CGFloat, on view: UIView) {
    guard minHeight > 0 else { return }
    if let existing = objc_getAssociatedObject(view, &AlertHeightBoostKeys.minHeightConstraint) as? NSLayoutConstraint {
        if minHeight > existing.constant { existing.constant = minHeight }
        return
    }
    let c = view.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight)
    c.priority = UILayoutPriority(999)
    c.isActive = true
    objc_setAssociatedObject(view, &AlertHeightBoostKeys.minHeightConstraint, c, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

private func raiseHeightConstraints(on view: UIView, toAtLeast minHeight: CGFloat) {
    guard minHeight > 0 else { return }
    for c in allConstraintsInvolving(view) where isAdjustableHeightConstraint(c, for: view) {
        let baseline: CGFloat
        if let stored = objc_getAssociatedObject(c, &AlertHeightBoostKeys.constraintBaseline) as? NSNumber {
            baseline = CGFloat(truncating: stored)
        } else {
            baseline = c.constant
            objc_setAssociatedObject(
                c,
                &AlertHeightBoostKeys.constraintBaseline,
                baseline,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
        if c.constant < minHeight {
            c.constant = max(minHeight, baseline)
        }
    }
}

private func expandParentChildHeightLinkages(parent: UIView, child: UIView, minParentHeight: CGFloat) {
    let childHeight = child.bounds.height
    guard childHeight > 0, minParentHeight > childHeight else { return }
    let neededConstant = minParentHeight - childHeight
    for c in allConstraintsInvolving(parent) {
        guard c.relation == .equal, c.multiplier == 1 else { continue }
        let first = c.firstItem as? UIView
        let second = c.secondItem as? UIView
        let linksHeights =
            (first === parent && c.firstAttribute == .height && second === child && c.secondAttribute == .height)
            || (first === child && c.firstAttribute == .height && second === parent && c.secondAttribute == .height)
        guard linksHeights else { continue }
        if first === parent, c.constant < neededConstant {
            c.constant = neededConstant
        }
    }
}

private func fitAlertParent(_ parent: UIView, toChild child: UIView) {
    parent.layoutIfNeeded()
    child.layoutIfNeeded()
    guard child.bounds.height > 0 else { return }
    let required = requiredHeightToFitChild(child, in: parent)
    guard required > parent.bounds.height + 0.5 else { return }
    raiseHeightConstraints(on: parent, toAtLeast: required)
    ensureAlertSequenceMinimumHeight(required, on: parent)
    expandParentChildHeightLinkages(parent: parent, child: child, minParentHeight: required)
}

private func measuredActionSequenceClippingDeficit(for stack: UIStackView) -> CGFloat {
    stack.layoutIfNeeded()
    var maxDeficit: CGFloat = 0
    var child: UIView = stack
    for parent in alertActionParentChain(from: stack) {
        parent.layoutIfNeeded()
        child.layoutIfNeeded()
        let required = requiredHeightToFitChild(child, in: parent)
        let deficit = required - parent.bounds.height
        if deficit > maxDeficit { maxDeficit = deficit }
        child = parent
    }
    return max(0, maxDeficit)
}

/// Propagate the laid-out stack height up through RepresentationsSequence and ancestors.
private func syncAlertActionSequenceParentHeights(for stack: UIStackView) {
    guard stack.axis == .vertical else {
        for parent in alertActionParentChain(from: stack) {
            clearAlertSequenceMinimumHeight(on: parent)
        }
        return
    }
    stack.layoutIfNeeded()
    var child: UIView = stack
    for parent in alertActionParentChain(from: stack) {
        fitAlertParent(parent, toChild: child)
        child = parent
    }
}

private func setAlertHeightBoost(_ boost: CGFloat, on constraint: NSLayoutConstraint) {
    let baseline: CGFloat
    if let stored = objc_getAssociatedObject(constraint, &AlertHeightBoostKeys.constraintBaseline) as? NSNumber {
        baseline = CGFloat(truncating: stored)
    } else {
        baseline = constraint.constant
        objc_setAssociatedObject(
            constraint,
            &AlertHeightBoostKeys.constraintBaseline,
            baseline,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
    constraint.constant = baseline + boost
}

private func applyHeightBoost(_ boost: CGFloat, to view: UIView) {
    for c in view.constraints where isAdjustableHeightConstraint(c, for: view) {
        setAlertHeightBoost(boost, on: c)
    }
    guard let superview = view.superview else { return }
    for c in superview.constraints {
        guard constraint(c, involves: view), isAdjustableHeightConstraint(c, for: view) else { continue }
        setAlertHeightBoost(boost, on: c)
    }
}

private func boostAlertControllerNamedHeightConstraints(on view: UIView, totalBoost: CGFloat) {
    for key in alertControllerNamedHeightConstraintKeys {
        guard let constraint = alertControllerHeightConstraint(on: view, key: key) else { continue }
        setAlertHeightBoost(totalBoost, on: constraint)
    }
}

private func applyAlertDialogHeightBoost(for stack: UIStackView, allowAsyncRetry: Bool = true) {
    guard isAlertSeparatableSequenceStack(stack), !AlertHeightBoostGuard.isActive else { return }
    AlertHeightBoostGuard.isActive = true
    defer { AlertHeightBoostGuard.isActive = false }

    guard stack.axis == .vertical else {
        for parent in alertActionParentChain(from: stack) {
            clearAlertSequenceMinimumHeight(on: parent)
        }
        return
    }

    syncAlertActionSequenceParentHeights(for: stack)

    let nominalBoost = extraVerticalAlertActionSpacingHeight(for: stack)
    let clipDeficit = measuredActionSequenceClippingDeficit(for: stack)
    let totalBoost = max(nominalBoost, clipDeficit)
    guard totalBoost > 0 else { return }
    if let layoutView = findAlertControllerLayoutView(startingFrom: stack) {
        boostAlertControllerNamedHeightConstraints(on: layoutView, totalBoost: totalBoost)
        applyHeightBoost(totalBoost, to: layoutView)
        for view in alertActionParentChain(from: stack) {
            applyHeightBoost(totalBoost, to: view)
        }
    }

    if allowAsyncRetry {
        DispatchQueue.main.async { [weak stack] in
            guard let stack, stack.window != nil else { return }
            applyAlertDialogHeightBoost(for: stack, allowAsyncRetry: false)
        }
    }
}

private func forceAlertButtonStackSpacing(_ stack: UIStackView) {
    guard isAlertSeparatableSequenceStack(stack) else { return }
    stack.spacing = alertActionSpacing
    applyAlertDialogHeightBoost(for: stack)
}

private func styleAlertControllerActionView(_ action: UIView, host: UIView) {
    let h = action.bounds.height
    guard h > 4, action.bounds.width > 4 else { return }
    let traits = action.traitCollection
    var fill = alertActionFillColor(for: host)
    let titleLabel = alertActionTitleLabel(in: action)
    let isDefaultAction = titleLabel.map { isAlertActionLabelBold($0) } ?? false
    if isDefaultAction, let titleLabel {
        fill = alertActionLabelAccentColor(action: action, label: titleLabel, traits: traits)
    }
    let radius = h * 0.5

    action.backgroundColor = fill
    action.layer.backgroundColor = fill.cgColor
    applyAlertActionPillCornerRadius(radius, to: action)
    if let representation = alertActionCustomViewRepresentationParent(of: action) {
        applyAlertActionPillCornerRadius(radius, to: representation)
    }

    for sub in action.subviews {
        let name = String(describing: type(of: sub))
        if name.contains("Backdrop") || name.contains("Material") || name.contains("VisualEffect") {
            sub.isHidden = true
            sub.alpha = 0
            sub.layer.opacity = 0
            killBackdropLayers(in: sub.layer)
        } else if name.contains("Highlight") || name.contains("Background") {
            sub.backgroundColor = .clear
            sub.layer.backgroundColor = UIColor.clear.cgColor
            sub.layer.cornerRadius = 0
            sub.layer.masksToBounds = false
        }
    }

    if isDefaultAction, let titleLabel {
        setAlertDefaultActionTitleWhite(action: action, label: titleLabel)
        let defaultFill = fill
        DispatchQueue.main.async { [weak action, weak titleLabel] in
            guard let action, let titleLabel, action.window != nil else { return }
            guard isAlertActionLabelBold(titleLabel) else { return }
            action.backgroundColor = defaultFill
            action.layer.backgroundColor = defaultFill.cgColor
            setAlertDefaultActionTitleWhite(action: action, label: titleLabel)
        }
    }
}

private func styleAlertActionButtons(in stack: UIStackView, host: UIView) {
    guard !AlertLayoutGuard.isLayoutingActions else { return }
    AlertLayoutGuard.isLayoutingActions = true
    defer { AlertLayoutGuard.isLayoutingActions = false }

    let buttons = alertControllerActionViews(in: stack)
    guard !buttons.isEmpty else { return }
    for action in buttons {
        styleAlertControllerActionView(action, host: host)
    }
}

private func layoutAndStyleAlertActions(in group: UIView) {
    guard !AlertLayoutGuard.isLayoutingActions else { return }
    AlertLayoutGuard.isLayoutingActions = true
    defer { AlertLayoutGuard.isLayoutingActions = false }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for container in alertActionSequenceContainers(in: group) {
        guard let stack = findAlertButtonStack(in: container) else { continue }
        forceAlertButtonStackSpacing(stack)
        styleAlertActionButtons(in: stack, host: group)
    }
    CATransaction.commit()
}

@_silgen_name("LGStyleAlertActionRepresentationView")
public func styleAlertActionRepresentationView(_ representation: UIView) {
    guard isKnockoutBackdropEnabled(), isAlertActionCustomViewRepresentation(representation) else { return }
    guard let actionClass = NSClassFromString("_UIAlertControllerActionView") else { return }
    var walk = [representation]
    while let view = walk.popLast() {
        if view.isKind(of: actionClass), view.bounds.height > 4 {
            applyAlertActionPillCornerRadius(view.bounds.height * 0.5, to: representation)
            return
        }
        walk.append(contentsOf: view.subviews)
    }
}

@_silgen_name("LGStyleAlertControllerActionView")
public func styleAlertControllerActionViewHook(_ action: UIView) {
    guard isKnockoutBackdropEnabled() else { return }
    guard String(describing: type(of: action)).contains("AlertControllerActionView") else { return }
    var host: UIView = action
    var v: UIView? = action.superview
    while let parent = v {
        let name = String(describing: type(of: parent))
        if name.contains("InterfaceActionGroup") || name.contains("AlertController") {
            host = parent
            break
        }
        v = parent.superview
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if let buttonStack = enclosingAlertActionButtonStack(for: action) {
        forceAlertButtonStackSpacing(buttonStack)
    }
    if AlertLayoutGuard.isLayoutingActions {
        styleAlertControllerActionView(action, host: host)
    } else {
        styleAlertControllerActionView(action, host: host)
        if let buttonStack = enclosingAlertActionButtonStack(for: action) {
            styleAlertActionButtons(in: buttonStack, host: host)
        }
    }
    CATransaction.commit()
}

@_silgen_name("LGApplyAlertActionSequenceSpacing")
public func applyAlertActionSequenceSpacing(_ container: UIView) {
    guard isKnockoutBackdropEnabled(), isAlertActionSequenceContainer(container) else { return }
    guard let stack = findAlertButtonStack(in: container) else { return }
    forceAlertButtonStackSpacing(stack)
    // Layout often resets spacing during %orig — re-apply once the pass finishes.
    DispatchQueue.main.async {
        guard stack.window != nil else { return }
        stack.spacing = alertActionSpacing
        applyAlertDialogHeightBoost(for: stack)
    }
}

@_silgen_name("LGStyleAlertActionSequenceButtons")
public func styleAlertActionSequenceButtons(_ container: UIView) {
    guard isKnockoutBackdropEnabled(), isAlertActionSequenceContainer(container) else { return }
    guard let stack = findAlertButtonStack(in: container) else { return }
    var host: UIView = container
    var v: UIView? = container.superview
    while let parent = v {
        let name = String(describing: type(of: parent))
        if name.contains("InterfaceActionGroup") || name.contains("AlertController") {
            host = parent
            break
        }
        v = parent.superview
    }
    styleAlertActionButtons(in: stack, host: host)
}

@_silgen_name("LGEnforceAlertActionStackSpacing")
public func enforceAlertActionStackSpacing(_ stack: UIView, _ spacing: CGFloat) -> CGFloat {
    guard let stack = stack as? UIStackView, isAlertSeparatableSequenceStack(stack) else { return spacing }
    return spacing < alertActionSpacing - 0.5 ? alertActionSpacing : spacing
}

@_silgen_name("LGLayoutAlertActionGroup")
public func layoutAlertActionGroup(_ group: UIView) {
    guard isKnockoutBackdropEnabled(), group.bounds.width > 0 else { return }
    layoutAndStyleAlertActions(in: group)
}

@_silgen_name("LGApplyAlertDialogHeightBoost")
public func applyAlertDialogHeightBoostFromRoot(_ root: UIView) {
    guard isKnockoutBackdropEnabled() else { return }
    for container in alertActionSequenceContainers(in: root) {
        guard let stack = findAlertButtonStack(in: container) else { continue }
        applyAlertDialogHeightBoost(for: stack)
    }
}

private func forceAlertDialogGlassInHierarchy(_ root: UIView) {
    guard let koClass = NSClassFromString("_UIDimmingKnockoutBackdropView") else { return }
    var stack = [root]
    while let view = stack.popLast() {
        if view.isKind(of: koClass), isAlertDialogKnockout(view),
           let glass = storedDimmingKnockoutGlass(for: view),
           let parent = view.superview {
            syncKnockoutReplacementGlass(
                glass,
                knockout: view,
                in: parent,
                cornerRadius: alertDialogGlassCornerRadius,
                alertCardStyle: true
            )
        }
        stack.append(contentsOf: view.subviews)
    }
}

@_silgen_name("LGHideAlertVibrantSeparator")
public func hideAlertVibrantSeparator(_ view: UIView) {
    guard isKnockoutBackdropEnabled() else { return }
    view.isHidden = true
    view.alpha = 0
    view.layer.opacity = 0
}

@_silgen_name("LGApplyAlertPresentation")
public func applyAlertPresentation(_ root: UIView) {
    guard isKnockoutBackdropEnabled() else { return }
    guard !AlertLayoutGuard.isApplyingChrome else { return }
    AlertLayoutGuard.isApplyingChrome = true
    defer { AlertLayoutGuard.isApplyingChrome = false }
    applyDimmingKnockoutInHierarchy(root)
    applyAlertDialogChrome(root)
}

@_silgen_name("LGApplyAlertDialogChrome")
public func applyAlertDialogChrome(_ root: UIView) {
    guard isKnockoutBackdropEnabled() else { return }

    if isAlertDialogContainer(root) {
        forceAlertDialogGlassInHierarchy(root)
        syncAlertDialogContainerGlass(root)
    }

    var stack = [root]
    while let view = stack.popLast() {
        let name = String(describing: type(of: view))
        if name.contains("InterfaceActionVibrantSeparator") {
            hideAlertVibrantSeparator(view)
        }
        stack.append(contentsOf: view.subviews)
    }
}

@_silgen_name("LGApplyToDimmingKnockoutBackdrop")
public func applyToDimmingKnockoutBackdrop(_ knockout: UIView) {
    guard isKnockoutBackdropEnabled() else { return }
    guard let parent = knockout.superview else { return }
    let alertDialog = isAlertDialogKnockout(knockout)
    let cornerR = dimmingKnockoutCornerRadius(for: knockout)

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    completelyHideDimmingKnockout(knockout)

    if let gv = storedDimmingKnockoutGlass(for: knockout) {
        syncKnockoutReplacementGlass(
            gv, knockout: knockout, in: parent, cornerRadius: cornerR, alertCardStyle: alertDialog
        )
        gv.liquidGlassView?.noteHostBecameVisible()
        CATransaction.commit()
        return
    }

    let effect = alertDialog ? makeAlertDialogGlassEffect(for: knockout) : LiquidGlassEffect(style: .clear, isNative: false)
    let gv = LiquidGlassEffectView(effect: effect)
    gv.isUserInteractionEnabled = false
    syncKnockoutReplacementGlass(
        gv, knockout: knockout, in: parent, cornerRadius: cornerR, alertCardStyle: alertDialog
    )
    storeDimmingKnockoutGlass(gv, for: knockout)
    gv.captureBackground()

    CATransaction.commit()
}

// MARK: - Folder icon (SBFolderIconImageView — the 60×60 rounded-rect grid view)

private func storedFolderIconGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.fi) as? LiquidGlassEffectView
}
private func storeFolderIconGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.fi, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

// MARK: - Open folder background (SBFolderBackgroundView)

private func storedOpenFolderGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.fo) as? LiquidGlassEffectView
}
private func storeOpenFolderGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.fo, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

/// Disable CABackdropLayer compositing recursively — needed because it renders at server level.
/// Pass skipLayer to protect a specific layer subtree (e.g. our glass view's backdrop).
private func killBackdropLayers(in layer: CALayer, skipping skipLayer: CALayer? = nil) {
    let backdropClass: AnyClass? = NSClassFromString("CABackdropLayer")
    for sub in layer.sublayers ?? [] {
        if let sl = skipLayer, sub === sl { continue }
        if let bc = backdropClass, sub.isKind(of: bc) {
            sub.setValue(false, forKey: "enabled")
            sub.opacity = 0
        }
        killBackdropLayers(in: sub, skipping: skipLayer)
    }
}

/// Walk a layer tree and set enabled=YES on all CABackdropLayers.
private func enableBackdropLayers(in layer: CALayer) {
    let backdropClass: AnyClass? = NSClassFromString("CABackdropLayer")
    for sub in layer.sublayers ?? [] {
        if let bc = backdropClass, sub.isKind(of: bc) {
            sub.setValue(true, forKey: "enabled")
            sub.opacity = 1
        }
        enableBackdropLayers(in: sub)
    }
}

/// Hide the glass immediately and schedule a reveal — call this every time the folder is about to open.
@_silgen_name("LGHideFolderGlass")
public func hideFolderGlass(_ view: UIView) {
    guard let gv = storedOpenFolderGlass(for: view) else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gv.alpha = 0
    // Keep backdrop layers enabled so they are ready when we fade in.
    CATransaction.commit()
    deferFolderGlass(gv)
}

private func deferFolderGlass(_ gv: LiquidGlassEffectView) {
    // Non-fullQuality folder glass uses the shared frozen wallpaper texture —
    // captureBackground() returns in microseconds (no layer.render work).
    // Show immediately to eliminate the black flash during folder open.
    gv.alpha = 0
    gv.captureBackground()  // pre-warms backgroundTexture from the frozen shared texture
    gv.isHidden = false
    UIView.animate(withDuration: 0.3, delay: 0.05, options: .curveEaseOut) {
        gv.alpha = 1
    }
}

@_silgen_name("LGApplyToFolderBackground")
public func applyToFolderBackground(_ view: UIView) {
    guard isFolderEnabled(), view.bounds.width > 0 else { return }

    let r = max(view.layer.cornerRadius > 0 ? view.layer.cornerRadius : 0, 36)

    if let gv = storedOpenFolderGlass(for: view) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gv.frame = view.bounds
        gv.layer.cornerRadius = r
        CATransaction.commit()
        // Always defer — willMoveToWindow:newWindow hides it before every open.
        if gv.isHidden {
            deferFolderGlass(gv)
        }
        return
    }

    // First-time setup: clear background, kill blur subviews, insert glass.
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    view.backgroundColor = .clear
    view.layer.backgroundColor = UIColor.clear.cgColor

    for sub in view.subviews {
        sub.isHidden = true
        sub.layer.opacity = 0
        killBackdropLayers(in: sub.layer)
    }
    killBackdropLayers(in: view.layer)

    // Non-fullQuality: uses the shared frozen wallpaper texture — available immediately,
    // no layer.render(in:) delay, eliminates the black flash during folder open.
    var effect = LiquidGlassEffect(style: .clear, isNative: false)
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = view.bounds
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = r
    gv.layer.cornerCurve  = .continuous
    gv.clipsToBounds = false  // Disable clipping during folder scale to fix black bars
    gv.alpha = 0
    gv.isHidden = true
    view.insertSubview(gv, at: 0)
    storeOpenFolderGlass(gv, for: view)

    CATransaction.commit()

    deferFolderGlass(gv)
}

@_silgen_name("LGApplyToFolderIcon")
public func applyToFolderIcon(_ view: UIView) {
    guard isFolderEnabled(), view.bounds.width > 0 else { return }

    // Clear view-level background color
    view.backgroundColor = .clear
    view.layer.backgroundColor = UIColor.clear.cgColor

    // Sync or create glass view
    let glassLayer: CALayer
    let r = view.layer.cornerRadius > 0 ? view.layer.cornerRadius : view.bounds.width * 0.22
    if let gv = storedFolderIconGlass(for: view) {
        gv.isHidden = false
        gv.frame = view.bounds
        gv.layer.cornerRadius = r
        view.sendSubviewToBack(gv)
        glassLayer = gv.layer
    } else {
        // .clear: high-quality glass blur without the frosted white/grey tint.
        // Quality now matches .regular (scaleCoefficient=0.5, blurRadius=0.5) but no fill tint.
        let effect = LiquidGlassEffect(style: .clear, isNative: false)
        let gv = LiquidGlassEffectView(effect: effect)
        gv.frame = view.bounds
        gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        gv.isUserInteractionEnabled = false
        gv.layer.cornerRadius = r
        gv.layer.cornerCurve  = .continuous
        gv.clipsToBounds = true
        view.insertSubview(gv, at: 0)
        storeFolderIconGlass(gv, for: view)
        glassLayer = gv.layer
    }

    // Hide background CALayers. The grey fill layer has an explicit backgroundColor
    // set on it; icon draw layers have backgroundColor == nil (they render via display
    // callback). So only hide layers that have a visible, non-clear backgroundColor.
    for sublayer in view.layer.sublayers ?? [] {
        if sublayer === glassLayer { continue }
        if sublayer.contents != nil { continue }
        guard let bg = sublayer.backgroundColor, bg.alpha > 0.01 else { continue }
        sublayer.isHidden = true
        sublayer.backgroundColor = UIColor.clear.cgColor
    }

    // Hide any background subviews
    for sub in view.subviews {
        if let gv = storedFolderIconGlass(for: view), sub === gv { continue }
        if sub is UIImageView || sub is UILabel { continue }
        if let vev = sub as? UIVisualEffectView { vev.effect = nil; vev.backgroundColor = .clear; continue }
        let n = String(describing: type(of: sub))
        if n.contains("Background") || n.contains("Backdrop") || n.contains("Shadow") || n.contains("Material") {
            sub.isHidden = true
        }
    }
}

@_silgen_name("LGRemoveFolderIconGlass")
public func removeFolderIconGlass(_ view: UIView) {
    if let gv = storedFolderIconGlass(for: view) {
        gv.removeFromSuperview()
    }
}

// MARK: - Lock screen media player (CSAdjunctItemView / MPUSystemMediaControlsView)

private func storedMediaPlayerGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.mp) as? LiquidGlassEffectView
}
private func storeMediaPlayerGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.mp, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

private func storedControlCenterGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.cc) as? LiquidGlassEffectView
}
private func storeControlCenterGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.cc, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@_silgen_name("LGApplyToControlCenterBackground")
public func applyToControlCenterBackground(_ view: UIView) {
    guard isControlCenterEnabled(), view.bounds.width > 0 else { return }

    let radius: CGFloat = view.layer.cornerRadius > 0.5 ? view.layer.cornerRadius : 22
    if let gv = storedControlCenterGlass(for: view) {
        if gv.isHidden { gv.isHidden = false }
        if view.subviews.first !== gv { view.insertSubview(gv, at: 0) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gv.frame = view.bounds
        gv.layer.cornerRadius = radius
        CATransaction.commit()
        return
    }

    view.backgroundColor = .clear
    view.layer.backgroundColor = UIColor.clear.cgColor

    let effect = LiquidGlassEffect(style: .clear, isNative: false)
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = view.bounds
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = radius
    gv.layer.cornerCurve = .continuous
    gv.clipsToBounds = false
    view.insertSubview(gv, at: 0)
    storeControlCenterGlass(gv, for: view)
}

private func shouldPreserveControlCenterMaterialRecipe(_ recipe: String?) -> Bool {
    guard let recipe = recipe?.lowercased() else { return false }
    return recipe.contains("highlight") || recipe.contains("fill") || recipe.contains("slider") || recipe.contains("selected") || recipe.contains("active") || recipe.contains("modulefill")
}

private func shouldPreserveControlCenterSubview(named className: String) -> Bool {
    let name = className.lowercased()
    let preserveKeywords = ["selected", "selection", "highlight", "module", "button", "toggle", "fill", "active", "ring", "pill", "press", "indicator", "state"]
    return preserveKeywords.contains(where: name.contains)
}

private func isControlCenterBackgroundSubview(named className: String) -> Bool {
    let name = className.lowercased()
    return name.contains("backdrop") || name.contains("blur") || name.contains("background")
}

private func viewContainsPreservedControlCenterMaterialLayer(_ view: UIView) -> Bool {
    let materialClass: AnyClass? = NSClassFromString("MTMaterialLayer")
    guard let mc = materialClass else { return false }
    func layerContainsPreserved(_ layer: CALayer) -> Bool {
        if layer.isKind(of: mc), shouldPreserveControlCenterMaterialRecipe(layer.value(forKey: "recipeName") as? String) {
            return true
        }
        for sub in layer.sublayers ?? [] {
            if layerContainsPreserved(sub) { return true }
        }
        return false
    }
    if layerContainsPreserved(view.layer) { return true }
    for subview in view.subviews {
        if layerContainsPreserved(subview.layer) { return true }
    }
    return false
}

private func shouldPreserveControlCenterOverlayView(_ view: UIView, in parent: UIView) -> Bool {
    let widthRatio = view.bounds.width / max(parent.bounds.width, 1)
    let heightRatio = view.bounds.height / max(parent.bounds.height, 1)
    let isSmallOverlay = widthRatio < 0.8 || heightRatio < 0.8

    if let bg = view.backgroundColor, bg.cgColor.alpha > 0.05 {
        if isSmallOverlay && !(view is UIVisualEffectView) {
            return true
        }
    }
    if let bg = view.layer.backgroundColor, UIColor(cgColor: bg).cgColor.alpha > 0.05 {
        if isSmallOverlay && !(view is UIVisualEffectView) {
            return true
        }
    }
    if view.layer.cornerRadius > 0.5 && min(view.bounds.width, view.bounds.height) > 8 {
        let radiusRatio = view.layer.cornerRadius / min(view.bounds.width, view.bounds.height)
        if radiusRatio > 0.3 && isSmallOverlay {
            return true
        }
    }
    return false
}

private func shouldPreserveControlCenterMaterialView(_ view: UIView) -> Bool {
    guard let materialClass: AnyClass = NSClassFromString("MTMaterialLayer") else { return false }
    if view.layer.isKind(of: materialClass) {
        if shouldPreserveControlCenterMaterialRecipe(view.layer.value(forKey: "recipeName") as? String) {
            return true
        }
    }
    for sublayer in view.layer.sublayers ?? [] {
        if sublayer.isKind(of: materialClass), shouldPreserveControlCenterMaterialRecipe(sublayer.value(forKey: "recipeName") as? String) {
            return true
        }
    }
    return shouldPreserveControlCenterSubview(named: String(describing: type(of: view)))
}

private func hideControlCenterMaterialLayers(in layer: CALayer) {
    let materialClass: AnyClass? = NSClassFromString("MTMaterialLayer")
    for sub in layer.sublayers ?? [] {
        if let mc = materialClass, sub.isKind(of: mc) {
            let preserve = shouldPreserveControlCenterMaterialRecipe(sub.value(forKey: "recipeName") as? String)
            if !preserve {
                sub.isHidden = true
                sub.backgroundColor = UIColor.clear.cgColor
            }
        }
        hideControlCenterMaterialLayers(in: sub)
    }
}

private func stripControlCenterBackgroundTopLevel(in view: UIView, glassView: UIView?) {
    if let gv = glassView, view === gv { return }

    view.backgroundColor = .clear
    view.layer.backgroundColor = UIColor.clear.cgColor
    view.layer.borderWidth = 0
    view.layer.borderColor = UIColor.clear.cgColor

    if let vev = view as? UIVisualEffectView {
        vev.effect = nil
        vev.backgroundColor = .clear
        vev.isHidden = true
        killBackdropLayers(in: vev.layer)
        return
    }

    for sub in view.subviews {
        if let gv = glassView, sub === gv { continue }
        let n = String(describing: type(of: sub))
        if let vev = sub as? UIVisualEffectView {
            let isFullSizeBackground = sub.bounds.width >= view.bounds.width * 0.85 && sub.bounds.height >= view.bounds.height * 0.85
            if isFullSizeBackground || (isControlCenterBackgroundSubview(named: n) && !shouldPreserveControlCenterSubview(named: n)) {
                vev.effect = nil
                vev.backgroundColor = .clear
                vev.isHidden = true
                killBackdropLayers(in: vev.layer)
            }
            continue
        }
        if let matViewClass = NSClassFromString("MTMaterialView"), sub.isKind(of: matViewClass) {
            if shouldPreserveControlCenterMaterialView(sub) {
                continue
            }
        }
        if shouldPreserveControlCenterOverlayView(sub, in: view) {
            continue
        }
        if isControlCenterBackgroundSubview(named: n) && !shouldPreserveControlCenterSubview(named: n) && !viewContainsPreservedControlCenterMaterialLayer(sub) {
            sub.isHidden = true
            continue
        }
        if let layerClass = NSClassFromString("MTMaterialLayer"), sub.layer.isKind(of: layerClass) {
            let preserve = shouldPreserveControlCenterMaterialRecipe(sub.layer.value(forKey: "recipeName") as? String)
            if !preserve {
                sub.isHidden = true
                continue
            }
        }
    }
}

private func stripControlCenterBackground(in view: UIView, glassView: UIView?) {
    if let gv = glassView, view === gv { return }

    view.backgroundColor = .clear
    view.layer.backgroundColor = UIColor.clear.cgColor
    view.layer.borderWidth = 0
    view.layer.borderColor = UIColor.clear.cgColor

    if let vev = view as? UIVisualEffectView {
        vev.effect = nil
        vev.backgroundColor = .clear
        vev.isHidden = true
        killBackdropLayers(in: vev.layer)
    }

    for sub in view.subviews {
        if let gv = glassView, sub === gv { continue }
        let n = String(describing: type(of: sub))
        if let vev = sub as? UIVisualEffectView {
            let isFullSizeBackground = sub.bounds.width >= view.bounds.width * 0.85 && sub.bounds.height >= view.bounds.height * 0.85
            if isFullSizeBackground || (isControlCenterBackgroundSubview(named: n) && !shouldPreserveControlCenterSubview(named: n)) {
                vev.effect = nil
                vev.backgroundColor = .clear
                vev.isHidden = true
                killBackdropLayers(in: vev.layer)
            }
            continue
        }
        if let matViewClass = NSClassFromString("MTMaterialView"), sub.isKind(of: matViewClass) {
            if shouldPreserveControlCenterMaterialView(sub) {
                continue
            }
        }
        if shouldPreserveControlCenterOverlayView(sub, in: view) {
            continue
        }
        if isControlCenterBackgroundSubview(named: n) && !shouldPreserveControlCenterSubview(named: n) && !viewContainsPreservedControlCenterMaterialLayer(sub) {
            sub.isHidden = true
            continue
        }
        if let layerClass = NSClassFromString("MTMaterialLayer"), sub.layer.isKind(of: layerClass) {
            let preserve = shouldPreserveControlCenterMaterialRecipe(sub.layer.value(forKey: "recipeName") as? String)
            if !preserve {
                sub.isHidden = true
                continue
            }
        }
        stripControlCenterBackground(in: sub, glassView: glassView)
    }
}

/// Control Center modules use their own material overlays. Strip them and insert liquid glass.
private func isControlCenterModuleAnimating(_ module: UIView) -> Bool {
    if let keys = module.layer.animationKeys(), !keys.isEmpty { return true }
    guard let presentation = module.layer.presentation() else { return false }
    if presentation.bounds != module.bounds { return true }
    if presentation.position != module.layer.position { return true }
    if !CATransform3DEqualToTransform(presentation.transform, module.layer.transform) { return true }
    var ancestor = module.superview
    while let view = ancestor {
        if let keys = view.layer.animationKeys(), !keys.isEmpty { return true }
        if !CATransform3DEqualToTransform(view.layer.transform, CATransform3DIdentity) { return true }
        ancestor = view.superview
    }
    return false
}

private func fadeInControlCenterGlass(_ gv: LiquidGlassEffectView) {
    gv.captureBackground()
    if gv.alpha < 1 {
        gv.alpha = 0
        gv.isHidden = false
        UIView.animate(withDuration: 0.18, delay: 0.0, options: .curveEaseOut) {
            gv.alpha = 1
        }
    }
}

private func scheduleControlCenterGlassRefresh(_ module: UIView) {
    if objc_getAssociatedObject(module, &K.ccRetry) != nil { return }
    objc_setAssociatedObject(module, &K.ccRetry, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    DispatchQueue.main.async { [weak module] in
        guard let module else { return }
        objc_setAssociatedObject(module, &K.ccRetry, nil, .OBJC_ASSOCIATION_ASSIGN)
        applyToControlCenterModule(module)
    }
}

/// Hide the glass view stored for a CC module without removing it.
/// Called when the module enters the long-press expanded state so our glass
/// doesn't interfere with the OS expansion animation (zoom-out glitch).
/// The glass is restored by LGApplyToControlCenterModule when the module
/// contracts back to its normal size (cc26ModuleExpanded returns NO).
@_silgen_name("LGHideControlCenterGlass")
public func hideControlCenterGlass(_ module: UIView) {
    guard let gv = storedControlCenterGlass(for: module) else { return }
    gv.isHidden = true
    gv.alpha = 0
}

@_silgen_name("LGApplyToControlCenterModule")
public func applyToControlCenterModule(_ module: UIView) {
    guard isControlCenterEnabled(), module.bounds.width > 0 else { return }

    let animating = isControlCenterModuleAnimating(module)
    let radius: CGFloat = module.layer.cornerRadius > 0.5 ? module.layer.cornerRadius : 22
    if let gv = storedControlCenterGlass(for: module) {
        if animating {
            // Distinguish bounds-change animations (long-press expand/contract) from
            // position-only animations (CC tray moving, spring physics etc.).
            // When bounds are changing, the existing glass texture is the WRONG SIZE —
            // showing it produces the "zoom out weird" stretch glitch. Hide it.
            // When only position/transform changes, keep glass visible to avoid a gap.
            let presB = module.layer.presentation()?.bounds ?? module.bounds
            let modelB = module.bounds
            if abs(presB.width - modelB.width) > 4 || abs(presB.height - modelB.height) > 4 {
                // Bounds expanding or contracting — hide to prevent stretch distortion.
                // applyToControlCenterModule will re-create the glass at the new size
                // once the animation settles and layoutSubviews fires again.
                gv.isHidden = true
                gv.alpha = 0
            } else {
                // Position-only animation — keep current glass visible.
                if gv.isHidden { gv.isHidden = false; gv.alpha = 1 }
            }
            return
        }
        if module.subviews.first !== gv { module.insertSubview(gv, at: 0) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gv.frame = module.bounds
        gv.layer.cornerRadius = radius
        gv.isHidden = false
        CATransaction.commit()
        fadeInControlCenterGlass(gv)
        GlassDisplayLink.shared.register(host: module, glass: gv, fallbackR: radius)
        return
    }
    if animating {
        // Create glass early so it is ready when the transition ends.
        let effect = LiquidGlassEffect(style: .regularHighBlur, isNative: false)
        effect.fullQuality = true
        effect.tintColor = .clear
        let gv = LiquidGlassEffectView(effect: effect)
        gv.frame = module.bounds
        gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        gv.isUserInteractionEnabled = false
        gv.layer.cornerRadius = radius
        gv.layer.cornerCurve = .continuous
        gv.clipsToBounds = false
        gv.alpha = 0
        gv.isHidden = true
        module.insertSubview(gv, at: 0)
        storeControlCenterGlass(gv, for: module)
        GlassDisplayLink.shared.register(host: module, glass: gv, fallbackR: radius)
        gv.liquidGlassView?.captureBackground()
        scheduleControlCenterGlassRefresh(module)
        return
    }

    stripControlCenterBackground(in: module, glassView: nil)

    let effect = LiquidGlassEffect(style: .regularHighBlur, isNative: false)
    effect.fullQuality = true
    effect.tintColor = .clear
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = module.bounds
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = radius
    gv.layer.cornerCurve = .continuous
    gv.clipsToBounds = false
    module.insertSubview(gv, at: 0)
    storeControlCenterGlass(gv, for: module)
    GlassDisplayLink.shared.register(host: module, glass: gv, fallbackR: radius)
}

/// Recursively strip all blur/tint/material views and clear backgrounds.
/// glassView: our LiquidGlassEffectView — skipped entirely so its own CABackdropLayer is never killed.
private func stripMediaPlayerBackground(in view: UIView, glassView: UIView?) {
    if let gv = glassView, view === gv { return }
    view.backgroundColor = .clear
    view.layer.backgroundColor = UIColor.clear.cgColor
    view.layer.borderWidth = 0
    // Kill backdrop layers, but SKIP the glass view's layer subtree so we don't disable our own glass.
    let skipLayer = glassView?.layer
    killBackdropLayers(in: view.layer, skipping: skipLayer)
    for sub in view.subviews {
        if let gv = glassView, sub === gv { continue }
        if let vev = sub as? UIVisualEffectView {
            vev.effect = nil
            vev.backgroundColor = .clear
            vev.isHidden = true
            killBackdropLayers(in: vev.layer, skipping: skipLayer)
            continue
        }
        let n = String(describing: type(of: sub))
        if n.contains("Backdrop") || n.contains("Background") ||
           n.contains("Tint") || n.contains("Material") || n.contains("Shadow") {
            sub.isHidden = true
            killBackdropLayers(in: sub.layer, skipping: skipLayer)
            continue
        }
        // Preserve actual content (buttons, labels, images, sliders, artwork)
        sub.backgroundColor = .clear
        sub.layer.backgroundColor = UIColor.clear.cgColor
        sub.layer.borderWidth = 0
        killBackdropLayers(in: sub.layer, skipping: skipLayer)
        stripMediaPlayerBackground(in: sub, glassView: glassView)
    }
}

@_silgen_name("LGApplyToMediaPlayer")
public func applyToMediaPlayer(_ view: UIView) {
    guard isMediaPlayerEnabled(), view.bounds.width > 0 else { return }

    let r: CGFloat = {
        let cl = view.layer.cornerRadius
        return cl > 1 ? cl : 26
    }()

    // Fast path: already set up — sync frame + shallow strip without killing backdrop layers.
    // IMPORTANT: do NOT call killBackdropLayers here — it walks the CALayer tree regardless
    // of view guards, and would disable the glass view's own CABackdropLayer every layout pass.
    if let gv = storedMediaPlayerGlass(for: view) {
        gv.isHidden = false
        gv.frame = view.bounds
        gv.layer.cornerRadius = r
        // Shallow strip: clear the container and its direct children only.
        view.backgroundColor = .clear
        view.layer.backgroundColor = UIColor.clear.cgColor
        view.layer.borderWidth = 0
        for sub in view.subviews {
            if sub === gv { continue }
            if let vev = sub as? UIVisualEffectView { vev.effect = nil; vev.isHidden = true; continue }
            let n = String(describing: type(of: sub))
            if n.contains("Backdrop") || n.contains("Background") ||
               n.contains("Tint") || n.contains("Material") || n.contains("Shadow") {
                sub.isHidden = true; continue
            }
            sub.backgroundColor = .clear
            sub.layer.backgroundColor = UIColor.clear.cgColor
            sub.layer.borderWidth = 0
        }
        view.sendSubviewToBack(gv)
        return
    }

    // First-time setup: strip backgrounds then add glass.
    stripMediaPlayerBackground(in: view, glassView: nil)

    let effect = LiquidGlassEffect(style: .clearBlur, isNative: false)
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = view.bounds
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = r
    gv.layer.cornerCurve = .continuous
    gv.clipsToBounds = false
    view.insertSubview(gv, at: 0)
    storeMediaPlayerGlass(gv, for: view)
}

/// Strip-only for inner control views (MPUSystemMediaControlsView etc.).
/// Does NOT add a glass view — the outer CSAdjunctItemView owns the single glass layer.
/// Fully recursive so grandchild backgrounds restored by UIKit are also caught.
@_silgen_name("LGStripMediaPlayerControls")
public func stripMediaPlayerControls(_ view: UIView) {
    guard isMediaPlayerEnabled() else { return }
    stripMediaPlayerBackground(in: view, glassView: nil)
}

// MARK: - Banner notification (NCNotificationShortLookView)

private func storedBannerGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.bn) as? LiquidGlassEffectView
}
private func storeBannerGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.bn, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@_silgen_name("LGApplyToBanner")
public func applyToBanner(_ banner: UIView) {
    guard isBannerEnabled(), banner.bounds.width > 0 else { return }

    // On the lock screen, NCNotificationShortLookView is a subview of NCNotificationListCell.
    // That outer cell already gets glassed by applyToNotificationCell — skip here to avoid
    // double glass.
    let cellClass: AnyClass? = NSClassFromString("NCNotificationListCell")
    if let cc = cellClass {
        var ancestor = banner.superview
        while let a = ancestor {
            if a.isKind(of: cc) { return }
            ancestor = a.superview
        }
    }

    // Fast path — glass already installed.
    if let gv = storedBannerGlass(for: banner) {
        if gv.isHidden { gv.isHidden = false }
        if banner.subviews.first !== gv { banner.sendSubviewToBack(gv) }
        return
    }

    let r: CGFloat = {
        let cl = banner.layer.cornerRadius
        return cl > 1 ? cl : 22
    }()

    stripNotificationBackground(in: banner, glassView: nil)

    let effect = LiquidGlassEffect(style: .regularHighBlur, isNative: false)
    effect.tintColor = .clear
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = banner.bounds
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = r
    gv.layer.cornerCurve = .continuous
    gv.clipsToBounds = false
    banner.insertSubview(gv, at: 0)
    storeBannerGlass(gv, for: banner)

    GlassDisplayLink.shared.register(host: banner, glass: gv, fallbackR: 22)
}

// MARK: - Notification cell (NCNotificationListCell)

private func storedNotificationGlass(for v: UIView) -> LiquidGlassEffectView? {
    objc_getAssociatedObject(v, &K.nc) as? LiquidGlassEffectView
}
private func storeNotificationGlass(_ gv: LiquidGlassEffectView, for v: UIView) {
    objc_setAssociatedObject(v, &K.nc, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

/// Recursively clear every background colour and kill every CABackdropLayer in a
/// notification cell subtree. UILabel / UIImageView have transparent backgrounds by
/// default, so only the tinted pill layer loses its fill.
/// NOTE: pass the stored glass view so we never recurse into it and kill its own backdropLayer.
private func stripNotificationBackground(in view: UIView, glassView: UIView?) {
    // Never touch our own glass view
    if let gv = glassView, view === gv { return }

    view.backgroundColor = .clear
    view.layer.backgroundColor = UIColor.clear.cgColor
    view.layer.borderWidth = 0
    view.layer.borderColor = UIColor.clear.cgColor
    // Kill CABackdropLayer compositor layers at this level
    killBackdropLayers(in: view.layer)

    for sub in view.subviews {
        // Never recurse into our own glass view
        if let gv = glassView, sub === gv { continue }

        // UIVisualEffectView: null the effect AND hide — can't just clear bg
        if let vev = sub as? UIVisualEffectView {
            vev.effect = nil
            vev.backgroundColor = .clear
            vev.isHidden = true
            killBackdropLayers(in: vev.layer)
            continue
        }
        let n = String(describing: type(of: sub))
        // Never recurse into UIButton — swipe-action "Clear" buttons live here and
        // stripping their subviews erases the title label rendering.
        if sub is UIButton { continue }
        // Named background-only views — hide entirely
        if n.contains("Backdrop") || n.contains("Background") ||
           n.contains("Tint") || n.contains("Material") || n.contains("WallpaperTint") {
            sub.isHidden = true
            killBackdropLayers(in: sub.layer)
            continue
        }
        // All other subviews: clear their fill and recurse
        sub.backgroundColor = .clear
        sub.layer.backgroundColor = UIColor.clear.cgColor
        sub.layer.borderWidth = 0
        sub.layer.borderColor = UIColor.clear.cgColor
        killBackdropLayers(in: sub.layer)
        stripNotificationBackground(in: sub, glassView: glassView)
    }
}

@_silgen_name("LGApplyToNotificationCell")
public func applyToNotificationCell(_ cell: UIView) {
    guard isNotificationEnabled(), cell.bounds.width > 0 else { return }

    // Skip nested NCNotificationListCell (group stacks have outer + inner cells).
    // Only the outermost cell gets glass; applying to inner ones creates double-glass.
    let cellClass: AnyClass? = NSClassFromString("NCNotificationListCell")
    if let cc = cellClass {
        var ancestor = cell.superview
        while let a = ancestor {
            if a.isKind(of: cc) { return }
            ancestor = a.superview
        }
    }

    // Fast path — GlassDisplayLink owns frame + cornerRadius sync at display refresh rate.
    // Zero subview iteration here; the one-time strip keeps backgrounds permanently clear.
    if let gv = storedNotificationGlass(for: cell) {
        if gv.isHidden { gv.isHidden = false }
        if cell.subviews.first !== gv { cell.sendSubviewToBack(gv) }
        return
    }

    // Only create glass on fully-expanded cells (identity transform).
    // Peeking / stacked cards have a scale+translate transform from NC; skip them until
    // the user expands the stack, at which point UIKit animates to identity and this
    // guard passes — glass is created lazily, one card at a time.
    guard cell.transform.isIdentity,
          CATransform3DIsIdentity(cell.layer.transform) else { return }

    let r: CGFloat = {
        let cl = cell.layer.cornerRadius
        return cl > 1 ? cl : 20
    }()

    // First-time setup — all heavy work runs exactly once
    stripNotificationBackground(in: cell, glassView: nil)

    let effect = LiquidGlassEffect(style: .regular, isNative: false)
    effect.tintColor = .clear
    let gv = LiquidGlassEffectView(effect: effect)
    gv.frame = cell.bounds
    gv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gv.isUserInteractionEnabled = false
    gv.layer.cornerRadius = r
    gv.layer.cornerCurve = .continuous
    gv.clipsToBounds = false
    cell.insertSubview(gv, at: 0)
    storeNotificationGlass(gv, for: cell)

    // Deferred reveal only while NC is opening (suspension window active). During
    // regular list scrolling, per-cell synchronous prewarm causes jank.
    let isInSuspensionWindow = CACurrentMediaTime() < LiquidGlassRenderer.shared.capturesSuspendedUntil
    if isInSuspensionWindow {
        gv.alpha = 0
        gv.captureBackground()
        UIView.animate(withDuration: 0.2, delay: 0.04, options: .curveEaseOut) { gv.alpha = 1 }
    } else {
        gv.alpha = 1
    }

    // Hand off to the display link for real-time frame + corner sync (30 fps on low-end)
    GlassDisplayLink.shared.register(host: cell, glass: gv, fallbackR: 20)
}

// MARK: - Global burst capture

// MARK: - Homescreen widget glass

/// Inject LiquidGlassEffectView into a homescreen widget's background container.
/// The MTMaterialView is hidden in Tweak.x before this is called; `host` is its
/// immediate parent UIView (the widget's rendering root).
private enum KWid {
    static var gv: UInt8 = 0
}

private let kWidgetGlassTag: Int = 0x4C475744  // "LGWD"

@_silgen_name("LGApplyToWidget")
public func applyToWidget(_ host: UIView) {
    guard isWidgetEnabled(), host.bounds.width > 60, host.bounds.height > 60 else { return }

    // Fast path — already glassed
    if let existing = objc_getAssociatedObject(host, &KWid.gv) as? UIView {
        if existing.isHidden { existing.isHidden = false }
        if host.subviews.first !== existing { host.sendSubviewToBack(existing) }
        return
    }

    let r: CGFloat = host.layer.cornerRadius > 1 ? host.layer.cornerRadius : 22

    let gv: UIView
    if #available(iOS 26.0, *) {
        // Native UIGlassEffect: composited entirely by the system's render server.
        // Zero Metal shader overhead per widget — the glass is driven by the same
        // hardware path as every built-in iOS 26 glass surface.
        // No CADisplayLink registration needed: autoresizingMask handles sizing.
        let nativeEffect = UIGlassEffect(style: .regular)
        let vev = UIVisualEffectView(effect: nativeEffect)
        vev.frame = host.bounds
        vev.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vev.isUserInteractionEnabled = false
        vev.layer.cornerRadius = r
        vev.layer.cornerCurve  = .continuous
        vev.clipsToBounds = true
        gv = vev
    } else {
        // iOS < 26 fallback: custom Metal renderer.
        let isDark = host.traitCollection.userInterfaceStyle == .dark
                 || UIScreen.main.traitCollection.userInterfaceStyle == .dark
        let effect = LiquidGlassEffect(style: .regular, isNative: false)
        if DeviceCapability.isLowEnd {
            let alpha: CGFloat = isDark ? 0.15 : DeviceCapability.tintAlpha
            let tint: UIColor  = isDark ? UIColor(white: 0.28, alpha: 1.0) : (effect.tintColor ?? .white)
            effect.tintColor = tint.withAlphaComponent(alpha)
        }
        let lgv = LiquidGlassEffectView(effect: effect)
        lgv.frame = host.bounds
        lgv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        lgv.isUserInteractionEnabled = false
        lgv.layer.cornerRadius = r
        lgv.layer.cornerCurve  = .continuous
        lgv.clipsToBounds = false
        let isInSuspensionWindow = CACurrentMediaTime() < LiquidGlassRenderer.shared.capturesSuspendedUntil
        if isInSuspensionWindow {
            lgv.alpha = 0
            lgv.captureBackground()
            UIView.animate(withDuration: 0.2, delay: 0.04, options: .curveEaseOut) { lgv.alpha = 1 }
        }
        GlassDisplayLink.shared.register(host: host, glass: lgv, fallbackR: r)
        gv = lgv
    }

    host.insertSubview(gv, at: 0)
    objc_setAssociatedObject(host, &KWid.gv, gv, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

// MARK: - Global burst capture

/// Tell every currently-rendering LiquidGlassView to enter burst-capture mode.
/// Call before major transitions (CC open/close, folder open, App Library reveal)
/// so all glass views refresh rapidly during the animation instead of showing
/// stale content captured before the transition started.
@_silgen_name("LGTriggerBurstCapture")
public func triggerBurstCapture() {
    LiquidGlassRenderer.shared.triggerGlobalBurst()
}

/// Suspend all existing-texture LiquidGlassView capture ticks for `duration` seconds.
/// Views showing their first frame are exempt and capture immediately as usual.
/// After the window expires every view auto-enters burst mode to refresh with clean content.
/// Use instead of LGTriggerBurstCapture for CC close, folder open, App Library transitions.
@_silgen_name("LGSuspendCaptures")
public func suspendCaptures(_ duration: Double) {
    // NOTE: invalidateSharedScreenCache() is intentionally NOT called here.
    // suspendCaptures(for:) schedules a deferred invalidation for after the suspension
    // window closes. This keeps the frozen pre-animation texture alive during the window
    // so newly-created glass views (e.g. App Library pods) render immediately with
    // correct pre-animation background instead of black, and the post-suspension burst
    // captures truly settled content when the deferred invalidation fires.
    LiquidGlassRenderer.shared.suspendCaptures(for: duration)
}

// MARK: - UISwitch → LiquidGlassSwitch overlay

/// Forwards value changes from the glass switch back to the hidden native UISwitch,
/// triggering any targets/actions the app already registered on it.
private class SwitchForwarder: NSObject {
    weak var nativeSwitch: UISwitch?

    @objc func glassSwitchChanged(_ sender: LiquidGlassSwitch) {
        guard let sw = nativeSwitch else { return }
        sw.setOn(sender.isOn, animated: false)
        sw.sendActions(for: .valueChanged)
    }
}

private enum KSw {
    static var gs:  UInt8 = 0   // stored LiquidGlassSwitch sibling
    static var fwd: UInt8 = 0   // stored SwitchForwarder
}

private func storedGlassSwitch(for sw: UISwitch) -> LiquidGlassSwitch? {
    objc_getAssociatedObject(sw, &KSw.gs) as? LiquidGlassSwitch
}

/// Hide only UISwitch's own private sublayers, leaving LiquidGlassSwitch's layer visible.
/// Must be called after every layoutSubviews because UISwitch rebuilds its sublayers.
private func hideNativeSwitchLayers(_ sw: UISwitch, glassLayer: CALayer) {
    sw.backgroundColor = .clear
    sw.layer.backgroundColor = UIColor.clear.cgColor
    for sublayer in sw.layer.sublayers ?? [] {
        if sublayer === glassLayer { continue }
        sublayer.opacity = 0
    }
}

/// Create the glass switch sibling and hide the native one.
@_silgen_name("LGSetupSwitchOverlay")
public func setupSwitchOverlay(_ sw: UISwitch) {
    guard isSwitchEnabled() else { return }
    guard storedGlassSwitch(for: sw) == nil else { return }
    // Defer until frame is real — syncSwitchOverlay will retry via layoutSubviews
    guard sw.bounds.width > 0 else { return }

    // Skip keyboard / IME accessories only
    if let sv = sw.superview {
        let n = String(describing: type(of: sv))
        guard !n.contains("Keyboard"),
              !n.contains("InputMethod"),
              !n.contains("InputAccessory") else { return }
    }

    let gs = LiquidGlassSwitch()
    gs.isOn = sw.isOn
    gs.onTintColor = sw.onTintColor
    gs.thumbTintColor = sw.thumbTintColor
    gs.isEnabled = sw.isEnabled
    // Center within UISwitch bounds (LiquidGlassSwitch is 63×28, UISwitch is 51×31)
    gs.center = CGPoint(x: sw.bounds.midX, y: sw.bounds.midY)

    let fwd = SwitchForwarder()
    fwd.nativeSwitch = sw
    gs.addTarget(fwd, action: #selector(SwitchForwarder.glassSwitchChanged(_:)), for: .valueChanged)

    // Allow the glass switch to visually overflow UISwitch's bounds
    sw.clipsToBounds = false
    sw.superview?.clipsToBounds = false

    // Add INSIDE UISwitch — hit-testing finds LiquidGlassSwitch as the deepest subview,
    // so UISwitch's own beginTracking: never fires.
    sw.addSubview(gs)
    sw.bringSubviewToFront(gs)

    // Hide UISwitch's own CALayers individually — we cannot use layer.opacity = 0
    // on UISwitch itself because that would also hide the LiquidGlassSwitch child layer.
    hideNativeSwitchLayers(sw, glassLayer: gs.layer)

    objc_setAssociatedObject(sw, &KSw.gs,  gs,  .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    objc_setAssociatedObject(sw, &KSw.fwd, fwd, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

/// Sync position + state — called every layoutSubviews on the native switch.
@_silgen_name("LGSyncSwitchOverlay")
public func syncSwitchOverlay(_ sw: UISwitch) {
    guard let gs = storedGlassSwitch(for: sw) else {
        // Setup was deferred — retry now that frame exists
        setupSwitchOverlay(sw)
        return
    }
    gs.center = CGPoint(x: sw.bounds.midX, y: sw.bounds.midY)
    if gs.isOn != sw.isOn { gs.setOn(sw.isOn, animated: false) }
    gs.isEnabled = sw.isEnabled
    sw.bringSubviewToFront(gs)
    // Re-hide UISwitch's layers every layout pass — UISwitch rebuilds them on state changes
    hideNativeSwitchLayers(sw, glassLayer: gs.layer)
}

/// Remove the glass switch and restore the native one.
@_silgen_name("LGTeardownSwitchOverlay")
public func teardownSwitchOverlay(_ sw: UISwitch) {
    if let gs = storedGlassSwitch(for: sw) {
        gs.removeFromSuperview()
    }
    objc_setAssociatedObject(sw, &KSw.gs,  nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    objc_setAssociatedObject(sw, &KSw.fwd, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    // Restore UISwitch layers
    for sublayer in sw.layer.sublayers ?? [] { sublayer.opacity = 1 }
    sw.backgroundColor = nil
}

// MARK: - UISlider → LiquidGlassSlider overlay

private class SliderForwarder: NSObject {
    weak var nativeSlider: UISlider?

    @objc func glassSliderChanged(_ sender: LiquidGlassSlider) {
        guard let s = nativeSlider else { return }
        s.setValue(sender.value, animated: false)
        s.sendActions(for: .valueChanged)
    }
}

private enum KSl {
    static var gs:  UInt8 = 0
    static var fwd: UInt8 = 0
}

private func storedGlassSlider(for s: UISlider) -> LiquidGlassSlider? {
    objc_getAssociatedObject(s, &KSl.gs) as? LiquidGlassSlider
}

/// Hide UISlider's own sublayers without touching the LiquidGlassSlider layer.
private func hideNativeSliderLayers(_ s: UISlider, glassLayer: CALayer) {
    s.backgroundColor = .clear
    s.layer.backgroundColor = UIColor.clear.cgColor
    for sublayer in s.layer.sublayers ?? [] {
        if sublayer === glassLayer { continue }
        sublayer.opacity = 0
    }
}

@_silgen_name("LGSetupSliderOverlay")
public func setupSliderOverlay(_ s: UISlider) {
    guard isSliderEnabled() else { return }
    guard storedGlassSlider(for: s) == nil else { return }
    guard s.bounds.width > 0 else { return }

    // Walk up the hierarchy and skip sliders that live on the lock screen or
    // inside the media player — those get glass from their parent card instead.
    var p: UIView? = s.superview
    while let ancestor = p {
        let n = String(describing: type(of: ancestor))
        // Media player container and its controls panel own their own glass.
        if n == "CSAdjunctItemView" || n == "MPUSystemMediaControlsView" { return }
        // Any lock screen surface (CoverSheet, CarPlay lock screen, etc.).
        if n.contains("CoverSheet") || n.contains("LockScreen") || n.contains("Dashboard") { return }
        // Keyboard/input accessories are already guarded below but catch them early too.
        if n.contains("Keyboard") || n.contains("InputMethod") || n.contains("InputAccessory") { return }
        p = ancestor.superview
    }
    // Also check the window class name — lock screen runs in SBCoverSheetWindow / CSCoverSheetWindow.
    if let winName = s.window.map({ String(describing: type(of: $0)) }),
       winName.contains("CoverSheet") || winName.contains("LockScreen") { return }

    let gs = LiquidGlassSlider()
    gs.frame = s.bounds
    gs.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    gs.value           = s.value
    gs.minimumValue    = s.minimumValue
    gs.maximumValue    = s.maximumValue
    gs.isContinuous    = s.isContinuous
    gs.minimumTrackTintColor = s.minimumTrackTintColor
    gs.maximumTrackTintColor = s.maximumTrackTintColor
    gs.thumbTintColor  = s.thumbTintColor
    gs.isEnabled       = s.isEnabled
    gs.minimumValueImage = s.minimumValueImage
    gs.maximumValueImage = s.maximumValueImage

    let fwd = SliderForwarder()
    fwd.nativeSlider = s
    gs.addTarget(fwd, action: #selector(SliderForwarder.glassSliderChanged(_:)), for: .valueChanged)

    s.clipsToBounds = false
    s.superview?.clipsToBounds = false

    s.addSubview(gs)
    s.bringSubviewToFront(gs)
    hideNativeSliderLayers(s, glassLayer: gs.layer)

    objc_setAssociatedObject(s, &KSl.gs,  gs,  .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    objc_setAssociatedObject(s, &KSl.fwd, fwd, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

@_silgen_name("LGSyncSliderOverlay")
public func syncSliderOverlay(_ s: UISlider) {
    guard let gs = storedGlassSlider(for: s) else {
        setupSliderOverlay(s)
        return
    }
    gs.frame = s.bounds
    if gs.value != s.value           { gs.setValue(s.value, animated: false) }
    if gs.minimumValue != s.minimumValue { gs.minimumValue = s.minimumValue }
    if gs.maximumValue != s.maximumValue { gs.maximumValue = s.maximumValue }
    gs.isEnabled = s.isEnabled
    s.bringSubviewToFront(gs)
    hideNativeSliderLayers(s, glassLayer: gs.layer)
}

@_silgen_name("LGTeardownSliderOverlay")
public func teardownSliderOverlay(_ s: UISlider) {
    if let gs = storedGlassSlider(for: s) { gs.removeFromSuperview() }
    objc_setAssociatedObject(s, &KSl.gs,  nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    objc_setAssociatedObject(s, &KSl.fwd, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    for sublayer in s.layer.sublayers ?? [] { sublayer.opacity = 1 }
    s.backgroundColor = nil
}
