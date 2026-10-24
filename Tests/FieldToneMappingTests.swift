import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct FieldToneMappingTests {
    static func main() {
        expect(FieldToneMapping.rate(forFieldChangeMicrotesla: 0.1) == nil,
               "weak signal should not start a tone")
        expect(FieldToneMapping.rate(forFieldChangeMicrotesla: .nan) == nil,
               "NaN must not produce a tone rate")
        expect(FieldToneMapping.rate(forFieldChangeMicrotesla: .infinity) == nil,
               "infinite input must not produce a tone rate")

        let minimum = FieldToneMapping.rate(
            forFieldChangeMicrotesla: FieldToneMapping.activationThresholdMicrotesla
        )
        let middle = FieldToneMapping.rate(forFieldChangeMicrotesla: 10)
        let maximum = FieldToneMapping.rate(
            forFieldChangeMicrotesla: FieldToneMapping.maximumMappedFieldMicrotesla
        )
        let overRange = FieldToneMapping.rate(forFieldChangeMicrotesla: 10_000)
        expect(minimum == FieldToneMapping.minimumPlaybackRate,
               "activation threshold should map to the lowest rate")
        expect((middle ?? 0) > (minimum ?? 100),
               "pitch rate should rise with field strength")
        expect((maximum ?? 0) > (middle ?? 100),
               "mapping should continue rising across the useful range")
        expect(maximum == FieldToneMapping.maximumPlaybackRate,
               "maximum reference field should map to max playback rate")
        expect(overRange == FieldToneMapping.maximumPlaybackRate,
               "extreme readings should clamp safely")
        expect((minimum ?? 0) >= 0.5 && (maximum ?? 0) <= 2.0,
               "playback rate must stay inside the intended audible range")

        let adaptiveMinimum = FieldToneMapping.rate(
            forFieldChangeMicrotesla: 2.5,
            activationThresholdMicrotesla: 2.5
        )
        expect(adaptiveMinimum == FieldToneMapping.minimumPlaybackRate,
               "noise-adjusted threshold should map to the lowest tone")
        expect(FieldToneMapping.rate(
            forFieldChangeMicrotesla: 1.0,
            activationThresholdMicrotesla: 2.5
        ) == nil, "tone should stay off while the signal is below the noise threshold")

        print("PASS: FieldToneMappingTests")
    }
}
