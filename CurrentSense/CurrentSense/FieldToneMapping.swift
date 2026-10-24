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
    static func rate(
        forFieldChangeMicrotesla field: Double,
        activationThresholdMicrotesla requestedThreshold: Double = activationThresholdMicrotesla
    ) -> Double? {
        let threshold = requestedThreshold.isFinite && requestedThreshold > 0
            ? max(activationThresholdMicrotesla, requestedThreshold)
            : activationThresholdMicrotesla
        guard field.isFinite, field >= threshold else { return nil }
        let ceiling = max(maximumMappedFieldMicrotesla, threshold * 4.0)
        let span = log(ceiling / threshold)
        guard span.isFinite, span > 0 else { return nil }

        let normalized = min(
            max(log(field / threshold) / span, 0.0),
            1.0
        )
        let rate = minimumPlaybackRate
            + normalized * (maximumPlaybackRate - minimumPlaybackRate)
        return rate.isFinite ? rate : nil
    }
}
