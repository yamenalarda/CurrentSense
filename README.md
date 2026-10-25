# CurrentSense

**Created and developed by Yamen Arada.**

CurrentSense is a minimal iPhone app that uses the iPhone's built-in magnetometer to explore magnetic-field changes near electrical cables.

- **DC mode:** displays magnetic-field change and only estimates current when a configured estimation method and signal-quality checks permit it.
- **AC mode:** qualitatively indicates AC magnetic-field activity as Detected / Not detected with a relative strength category. It does **not** display a numeric AC-current estimate.
- **Interface:** a glass-style measurement circle, simple AC/DC selection, compact readings, and optional sound feedback.

> **Safety notice:** CurrentSense is an experimental magnetic-field tool, not a safety instrument. AC mode detects magnetic-field activity, not voltage. A detected field does not prove a conductor is live, and no detection does not prove that it is safe. Never use this app in place of a certified voltage tester, multimeter, or clamp meter.

## Project status

| Area | Status |
|---|---|
| Swift / SwiftUI app source (iOS 17+) | Included |
| Core unit and regression tests | Included; CI must verify them |
| iPhone simulator UI tests | Included; CI must verify them |
| GitHub Actions build pipeline | Configured in this repository; check the latest run for actual status |
| Unsigned iOS archive / IPA packaging | Intended CI output; not directly installable without signing |
| Physical iPhone 15 validation and current-estimation accuracy | Not yet validated by CI; requires real-device experiments |

Treat the app as experimental until the automated tests pass and its behaviour is validated on physical hardware.

## Build from Windows using GitHub Actions

You do not need a Mac on your own computer. GitHub Actions runs the build on a hosted macOS machine.

1. Open the repository's **Actions** tab.
2. Select **Build and test (unsigned IPA)**.
3. Wait for the workflow to finish and inspect the test and archive steps.
4. If it succeeds, open the run and download the artifact named similar to `CurrentSense-unsigned-ipa-b<run>-<commit>`. It contains the unsigned IPA and a build report.
5. If it fails, download the `logs-b<run>` artifact and inspect the failing step before attempting to install anything.

The workflow runs the Swift package tests, generates the Xcode project with XcodeGen, runs simulator UI tests, archives a Release build, packages an unsigned IPA, verifies its metadata, and uploads the artifacts.

### Installing on an iPhone

The CI artifact is **unsigned** and cannot be installed directly on an iPhone. You must sign it using a legitimate signing workflow and your own Apple developer credentials. A free Apple ID may have restrictions and short-lived provisioning; this CI pipeline does not sign the app or bypass Apple's signing requirements.

Never commit Apple ID passwords, signing certificates, private keys, or provisioning profiles to this repository.

## How to use the app

1. Select **AC** or **DC** at the top.
2. Tap the glass measurement circle to start. Keep the phone still during the approximately 2-second background-baseline capture; for DC, keep the load switched off while the baseline is collected.
3. **DC:** switch on the load and observe the magnetic-field change and signal quality. A current estimate is shown only when an estimation method is configured and the signal passes quality checks; otherwise, the app withholds the estimate.
4. **AC:** position the phone near the cable and observe detection and relative strength. AC mode does not calculate or show a numeric current.
5. Tap the circle again to stop.

If the phone moves or rotates after the baseline is captured, stop and restart the measurement so the baseline can be reacquired.

### DC current-estimation methods

- **Off:** field change only; no current estimate.
- **Calibrated:** use a known current from a trusted clamp meter. Calibration is specific to the cable, phone position, and orientation. Estimates are withheld when the signal is outside the configured validity range.
- **Ideal wire:** applies the ideal long-straight-conductor approximation. Real appliance cables often contain closely paired outgoing and return conductors whose fields partially cancel, so this method can be substantially inaccurate and should not be treated as a measurement-grade result.

## Architecture

The `Packages/CurrentSenseCore` Swift package contains the measurement models, baseline handling, DC and AC processing, estimation, quality rules, audio mapping, presentation logic, and measurement-pipeline state machine. The app target contains the sensor source, measurement engine, view model, audio feedback, and SwiftUI interface.

## Known limitations

See [docs/SCIENCE.md](CurrentSense/docs/SCIENCE.md). Sensor sampling and filtering vary by device and iOS version; AC frequency aliasing can cause missed or misclassified signals; the phone's movement is not fully tracked; the field cannot be attributed to one specific conductor; and the app does not measure distance. Thresholds and current-estimation accuracy still require validation with controlled tests and real instruments.

## License

This project is distributed under the **GNU General Public License v3.0 (GPL-3.0)**. See [LICENSE](LICENSE) for the full terms.

Copyright (c) 2026 Yamen Arada.
