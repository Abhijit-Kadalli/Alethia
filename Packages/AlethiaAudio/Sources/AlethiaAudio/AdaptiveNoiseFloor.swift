import Foundation

/// Asymmetric EMA noise floor (Sohn / WebRTC-style).
/// Updates only on noise-like frames so speech energy does not inflate the floor.
public final class AdaptiveNoiseFloor: @unchecked Sendable {
    public private(set) var floor: Float
    private let riseAlpha: Float
    private let fallAlpha: Float
    private let minFloor: Float
    private let margin: Float

    public init(
        initial: Float = 0.01,
        riseAlpha: Float = 0.05,
        fallAlpha: Float = 0.25,
        minFloor: Float = 0.002,
        margin: Float = 1.8
    ) {
        self.floor = max(initial, minFloor)
        self.riseAlpha = riseAlpha
        self.fallAlpha = fallAlpha
        self.minFloor = minFloor
        self.margin = margin
    }

    /// High-recall energy gate — precision lives in the speech scorer, not here.
    public func energyPassed(rms: Float) -> Bool {
        rms >= max(0.004, margin * floor)
    }

    public func update(rms: Float, noiseLike: Bool) {
        guard noiseLike else { return }
        if rms > floor {
            floor = (1 - riseAlpha) * floor + riseAlpha * rms
        } else {
            floor = (1 - fallAlpha) * floor + fallAlpha * rms
        }
        floor = max(floor, minFloor)
    }

    public func reset(to initial: Float = 0.01) {
        floor = max(initial, minFloor)
    }
}
