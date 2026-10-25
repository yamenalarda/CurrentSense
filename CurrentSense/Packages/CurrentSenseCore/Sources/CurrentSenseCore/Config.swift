import Foundation

/// All tunable thresholds in one place. Values are engineering starting points justified in
/// docs/SCIENCE.md; they are NOT validated on hardware yet (see README, "Known limitations").
public struct PipelineConfig: Equatable, Sendable {
    // Acquisition / validity
    public var acquisitionDuration = 2.0          // s of still, quiet data for the baseline
    public var minAcquisitionSamples = 40
    public var maxAcquisitionSamples = 2048
    public var minSampleRate = 20.0               // Hz
    public var maxBaselineSigma = 1.5             // µT, per-axis robust noise above this = unstable environment
    public var maxBaselineDrift = 1.0             // µT, first-half vs second-half median difference
    public var sigmaFloor = 0.05                  // µT, assumed minimum per-axis noise (quantisation guard)
    public var maxAcquisitionRotationRate = 0.35  // rad/s (~20 deg/s)
    public var maxOperatingRotationRate = 0.5     // rad/s
    public var motionHoldoff = 0.5                // s of rejection after rotation stops
    public var orientationInvalidationAngle = 0.14 // rad (~8 deg): baseline no longer applicable
    public var baselineMaxAge = 300.0             // s
    public var maxFieldMagnitude = 10_000.0       // µT, anything larger is implausible
    public var maxSampleGap = 0.25                // s, larger gap resets filters
    public var stallTimeout = 0.5                 // s without samples = stalled
    public var maxConsecutiveInvalid = 20
    public var publishInterval = 0.1              // s (10 Hz UI state)

    // DC
    public var dcSmoothingTau = 0.25
    public var dcDetectSNR = 3.0
    public var dcCurrentMinSNR = 10.0
    public var dcMaxSpread = 0.05
    public var dcHighConfidenceSNR = 30.0
    public var dcHighConfidenceSpread = 0.02
    public var spreadWindow = 1.0
    public var minSpreadSpan = 0.5
    public var extrapolationFactor = 2.0
    public var maxCurrentUncertainty = 0.5
    public var idealModelMinUncertainty = 0.3
    public var minIdealDistance = 0.002           // m
    public var maxIdealDistance = 0.5             // m

    // AC
    public var acHighPassHz = 8.0
    public var acRMSWindow = 1.0
    public var acMinSpan = 0.5
    public var acNoiseFloorMin = 0.03             // µT
    public var acEnterRatio = 2.0
    public var acExitRatio = 1.5
    public var acEnterDwell = 0.3
    public var acExitDwell = 0.5
    public var acModerateRatio = 4.0
    public var acStrongRatio = 10.0
    public var acCategoryHysteresis = 0.1
    public var spectrumWindow = 1.0
    public var mainsToneFraction = 0.35
    public var mainsScanHz = 1.0
    public var mainsScanStep = 0.25
    public var mainsMinAliasHz = 3.0
    public var mainsNyquistGuardHz = 1.5

    public static let `default` = PipelineConfig()
    public init() {}
}
