import Foundation

/// Converts raw RMS into a smoothed 0…1 meter value for waveform UI.
public struct AudioLevelMeter: Sendable {
    public private(set) var level: Float = 0
    private let attack: Float
    private let release: Float
    private let floorDb: Float

    public init(attack: Float = 0.6, release: Float = 0.15, floorDb: Float = -50) {
        self.attack = attack
        self.release = release
        self.floorDb = floorDb
    }

    public mutating func update(rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-6))
        let normalized = min(max((db - floorDb) / -floorDb, 0), 1)
        let coefficient = normalized > level ? attack : release
        level += (normalized - level) * coefficient
        return level
    }

    public mutating func reset() {
        level = 0
    }
}
