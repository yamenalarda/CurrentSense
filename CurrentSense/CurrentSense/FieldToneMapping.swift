import Foundation

/// Maps a measured magnetic-field change to a pleasant, bounded detector tone.
/// This is a UI feedback mapping only; it does not estimate current or improve sensor accuracy.
enum FieldToneMapping {
    static let activationThresholdMicrotesla = 0.75
    static let releaseThresholdMicrotesla = 0.45
    static let maximumMappedFieldMicrotesla = 80.0
    static let minimumPlaybackRate = 0.65
    static let maximumPlaybackRate = 2.0

    /// Returns nil below the activation threshold or for invalid sensor input.
    /// Logarithmic mapping keeps weak changes distinguishable without making
    /// high readings immediately pin the tone to its maximum pitch.
    static func rate(forFieldChangeMicrotesla field: Double) -> Double? {
        guard field.isFinite, field >= activationThresholdMicrotesla else { return nil }
        let span = log(maximumMappedFieldMicrotesla / activationThresholdMicrotesla)
        guard span.isFinite, span > 0 else { return nil }

        let normalized = min(
            max(log(field / activationThresholdMicrotesla) / span, 0.0),
            1.0
        )
        let rate = minimumPlaybackRate
            + normalized * (maximumPlaybackRate - minimumPlaybackRate)
        return rate.isFinite ? rate : nil
    }
}
