//
//  GlassMotionController.swift – drives glareDirectionOffset from device tilt.
//

import CoreMotion
import UIKit

/// Pushes accelerometer-derived glare angle into every active LiquidGlassView.
enum GlassMotionController {
    private static let motion = CMMotionManager()
    private static var running = false
    private static var observersInstalled = false
    private static var lastAngle: Float = .nan

    static func startIfNeeded() {
        guard !running else { return }

        let motionHz: Double = DeviceCapability.isLowEnd ? 15 : 20
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / motionHz
            motion.startDeviceMotionUpdates(
                using: .xArbitraryCorrectedZVertical,
                to: .main
            ) { data, _ in
                guard let gravity = data?.gravity else { return }
                deliverGlareAngle(angleFromGravity(gravity))
            }
            running = true
            return
        }

        guard motion.isAccelerometerAvailable else { return }
        motion.accelerometerUpdateInterval = 1.0 / motionHz
        motion.startAccelerometerUpdates(to: .main) { data, _ in
            guard let accel = data?.acceleration else { return }
            deliverGlareAngle(angleFromAcceleration(accel))
        }
        running = true
    }

    static func installLifecycleObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            if !running { startIfNeeded() }
        }
        // Do not stop on willResignActive — SpringBoard fires this constantly (NC/CC)
        // and would kill tilt glint while the home screen is still visible.
    }

    private static func angleFromGravity(_ gravity: CMAcceleration) -> Float {
        let gx = Float(gravity.x)
        let gy = Float(-gravity.y)
        return atan2(gy, gx) + .pi / 2
    }

    private static func angleFromAcceleration(_ accel: CMAcceleration) -> Float {
        angleFromGravity(accel)
    }

    private static func deliverGlareAngle(_ angle: Float) {
        if lastAngle.isFinite, abs(angle - lastAngle) < 0.02 { return }
        lastAngle = angle
        // CMMotionManager delivers on the main queue, but the handler closure is not @MainActor.
        Task { @MainActor in
            LiquidGlassRenderer.shared.updateGlareDirection(angle)
        }
    }
}
