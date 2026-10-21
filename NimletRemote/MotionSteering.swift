import Foundation
import CoreMotion
import Combine

/// Gyro pointer steering for the Air pill.
///
/// Uses `rotationRate` rather than `attitude`: we send deltas, so integrating
/// an absolute orientation would only add drift we would then have to correct.
@MainActor
final class MotionSteering: ObservableObject {

    @Published private(set) var isSteering = false
    /// The Simulator has no gyro, so the pill would never be visible there.
    /// This lets its layout be checked without a device; steering itself still
    /// does nothing until run on real hardware.
    @Published private(set) var isAvailable = CMMotionManager().isDeviceMotionAvailable
        || UserDefaults.standard.bool(forKey: "mice.air.forceShow")

    /// Sign conventions depend on how the phone is held and could not be
    /// verified without the device, so both axes are invertible and the gain is
    /// adjustable without a rebuild:
    ///   defaults write <app> mice.air.invertX -bool YES
    private let defaults = UserDefaults.standard
    private var gain: Double { defaults.object(forKey: "mice.air.gain") as? Double ?? 2200 }
    /// Without a curve, travel is purely `angle x gain`: at the old 1200 that
    /// meant ~143 degrees of rotation to cross both displays. Slow rotation now
    /// stays precise while fast rotation earns up to ~7x.
    private var accelStrength: Double { defaults.object(forKey: "mice.air.accel") as? Double ?? 2.5 }
    private var accelThreshold: Double { defaults.object(forKey: "mice.air.accelRate") as? Double ?? 2.0 }
    private var accelCap: Double { defaults.object(forKey: "mice.air.accelCap") as? Double ?? 2.5 }
    private var invertX: Bool { defaults.bool(forKey: "mice.air.invertX") }
    private var invertY: Bool { defaults.bool(forKey: "mice.air.invertY") }
    /// Below this the hand's natural tremor would creep the cursor.
    private var deadzone: Double { defaults.object(forKey: "mice.air.deadzone") as? Double ?? 0.012 }

    private let manager = CMMotionManager()
    private var onDelta: ((Double, Double) -> Void)?

    func start(onDelta: @escaping (Double, Double) -> Void) {
        guard manager.isDeviceMotionAvailable, !isSteering else { return }
        self.onDelta = onDelta
        isSteering = true

        manager.deviceMotionUpdateInterval = 1.0 / 120.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion, self.isSteering else { return }

            let rate = motion.rotationRate
            // Yaw steers horizontally, pitch steers vertically.
            var dx = -rate.z
            var dy = -rate.x
            if self.invertX { dx = -dx }
            if self.invertY { dy = -dy }

            let magnitude = (dx * dx + dy * dy).squareRoot()
            guard magnitude > self.deadzone else { return }

            let ratio = min(magnitude / self.accelThreshold, self.accelCap)
            let effectiveGain = self.gain * (1 + self.accelStrength * ratio)
            let step = self.manager.deviceMotionUpdateInterval * effectiveGain
            self.onDelta?(dx * step, dy * step)
        }
    }

    func stop() {
        guard isSteering else { return }
        isSteering = false
        manager.stopDeviceMotionUpdates()
        onDelta = nil
    }
}
