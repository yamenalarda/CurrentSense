# CurrentSense: related-project research and accuracy notes

Research reviewed on 2026-10-24. This document records design lessons, not claims that CurrentSense has been experimentally validated.

## Related projects and sources

- [MeasureBox](https://github.com/LEO2008k/MeasureBox) — its README describes a magnetometer detector with variable-frequency audio feedback, signal processing, and haptic feedback. Lesson applied: encode stronger field changes as a higher, smoothly changing tone rather than playing a new beep for every sensor update. CurrentSense implements its own mapping and audio engine; it does not copy that project's source.
- [Wall Scanner & Metal Detector](https://github.com/Lapnito/wall-scanner-metal-detector) — [README and calibration discussion](https://github.com/Lapnito/wall-scanner-metal-detector#figure-8-calibration) describe figure-eight motion calibration, real microtesla readings, per-axis debug values, saturation warnings, and CSV recording. Lessons for CurrentSense: preserve raw XYZ/time/calibration metadata; detect suspicious or saturated readings; make calibration visible; test against a reference instead of relying on the orb or tone alone.
- [iOS Magnetometer Demo](https://github.com/mryssng/MagnetometerDemo) — compares Core Motion calibrated magnetic field, raw Core Motion magnetometer data, and Core Location heading. Lesson: be explicit about which sensor stream is being used. Heading-compensated data is not interchangeable with a raw magnetic-field stream.
- [Apple Core Motion: CMMagnetometerData](https://developer.apple.com/documentation/coremotion/cmmagnetometerdata/magneticfield) — raw magnetometer values include the Earth's field plus device bias and surrounding fields; the calibrated CMDeviceMotion field can filter device bias and, in some cases, nearby fields. CurrentSense now uses raw magnetometer values for detecting field change, and uses device-motion attitude only to compensate for phone rotation. Calibration accuracy from CMDeviceMotion remains auxiliary metadata, not a quality guarantee for raw samples.
- [Apple AVAudioSession ambient category](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/ambient) — this category is designed for non-primary sound and is silenced by the iPhone Silent switch. CurrentSense uses this behavior instead of overriding the user's silent setting.
- Vongvizay & Udomsamuthirun, [Apply a smartphone's magnetometer to measure the AC current of electrical equipment](https://doi.org/10.1119/5.0233097), *The Physics Teacher* 63 (2025), 130–131. This is directly relevant research, but it does not by itself validate CurrentSense on an iPhone 15 or make the Core Motion stream a calibrated 50/60 Hz RMS instrument.

## Accuracy risks that remain

1. A phone's magnetic field includes the Earth's field, the phone's own bias, local magnets/steel, motor fields, orientation changes, and the test cable. A change in field is not uniquely a current measurement.
2. Phase and neutral conductors in a complete cable carry opposite currents; their fields can partly cancel. The single isolated-conductor equation must not be used for that cable geometry.
3. One reading cannot independently identify both current and distance. The full-cable mode therefore requires an empirical reference calibration and does not claim to calculate distance.
4. AC RMS accuracy must be demonstrated at the actual 50 Hz / 60 Hz frequency, raw magnetometer sample-rate behavior, load waveform, cable geometry, and phone placement. CurrentSense requests a 40 Hz update interval, but the actual delivery rate must be checked from timestamps and may differ. A 40 Hz stream cannot meet Nyquist for 50/60 Hz mains, so it cannot reconstruct the waveform or guarantee an AC RMS reading.
5. One-point sensitivity calibration is only a local approximation. A better validation should collect several known currents from a clamp meter, repeat at fixed positions/orientations and under several loads, fit the field-change/current relationship, and report residual error and range instead of only a single calibration number.
6. For research-grade confidence, add reproducible multi-point calibration, repeated trials, CSV export of timestamp + XYZ + vector change + reference current, robust filtering, sensor saturation/outlier warnings, per-device validation, and a written test report with mean absolute error / maximum error. Test both resistive and nonlinear loads and do not present estimates outside the validated range.

## Audio feedback added

- Tone is active only while measurement is running and filtered field change is above the noise-adjusted threshold.
- Pitch is mapped monotonically (logarithmically) to field-change magnitude and smoothed to reduce jitter.
- Tone stops when the signal drops below a lower release threshold, on measurement stop, or when the app becomes inactive.
- Audio uses the iOS ambient session category so the Silent switch is respected; no mute override is used.
- The tone is a visualization aid only. It does not indicate a certified current level or make AC RMS estimates more accurate.

## Latest signal path update

- Detection now uses `CMMagnetometerData.magneticField` (raw magnetic field) instead of the calibrated field exposed by `CMDeviceMotion`, because Apple's documentation says the calibrated stream can remove device bias and sometimes nearby fields. A separate device-motion stream supplies the attitude matrix for orientation compensation.
- Raw and filtered field-change values, baseline MAD noise, and actual delivery rate are exposed in diagnostic settings; CSV export records both raw and filtered deltas.
- A seven-sample median plus EMA reduces isolated spikes. The estimator rejects signals below the larger of 0.5 µT and five times measured baseline noise, and the UI preserves small current/distance values instead of rounding them to zero.
- These are signal-path and robustness improvements, not proof of accuracy. The raw stream, actual sample rate, 50/60 Hz response, and current estimates still require testing on the user's iPhone 15 against a reference clamp meter and known-current loads.
- The sensor callback handoff coalesces pending readings into a single latest-value slot. The main-actor drain yields between samples to avoid monopolizing UI work; interruption/stop clears stale baseline and displayed data while preserving the error message for diagnosis.
