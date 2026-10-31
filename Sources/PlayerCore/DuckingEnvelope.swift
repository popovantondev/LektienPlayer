import Foundation

/// A held, smoothed gain prevents pumping between syllables. Time is monotonic.
public struct DuckingEnvelope {
    public private(set) var gain = 1.0
    private var lastSpeech = -Double.infinity
    public init() {}

    public mutating func update(speaking: Bool, enabled: Bool, attenuation: Double,
                                time: Double, elapsed: Double) -> Double {
        if speaking { lastSpeech = time }
        let active = enabled && time - lastSpeech < 0.30
        let target = active ? min(1, max(0, attenuation)) : 1
        let duration = target < gain ? 0.10 : 0.65
        let step = min(1, max(0, elapsed) / duration)
        gain += (target - gain) * step
        if abs(gain - target) < 0.001 { gain = target }
        return gain
    }
}
