# CurrentSense

A minimal iPhone app that uses the built-in magnetometer to (DC) measure the magnetic-field change near a cable and, only when justified, estimate a current, and (AC) qualitatively indicate AC magnetic-field activity.

> **CurrentSense is not a safety instrument.** AC mode detects magnetic-field activity, not voltage. A detected field does not prove a conductor is live, and "not detected" does not prove it is safe. Never use it in place of a certified voltage tester, multimeter or clamp meter.

## Status (read this first)

| Item | State |
|---|---|
| Source code (Swift 5 / SwiftUI, iOS 17+, iPhone) | Written |
| Core unit + scientific regression tests (`swift test`) | Written; **not yet executed** (no Swift toolchain was available where this was authored) |
| UI tests (simulator, synthetic sensor) | Written; **not yet executed** |
| GitHub Actions workflow (macOS runner, unsigned IPA) | Written; **never run** |
| Physical iPhone 15 validation (sample rate, noise floor, appliance behaviour, current accuracy) | **Not performed** |
| Python prototype of the AC chain (`scripts/prototype_check.py`) | Executed; checks the *algorithm*, not the Swift code |

Until the workflow has run green, treat the code as unverified: it may contain compile errors. Fix whatever the first run reports.

## Requirements

- iPhone with a magnetometer (target: iPhone 15), iOS 17 or later. Portrait only.
- No external hardware, no Mac needed: builds run on a GitHub-hosted macOS runner.

## Build and get an IPA (Windows workflow)

1. Create a GitHub repository and push this folder (`git init`, `git add .`, `git commit`, `git push`).
2. Open **Actions -> "Build and test (unsigned IPA)"**. It runs on every push, or use *Run workflow*.
3. The job: toolchain info -> `swift test` -> XcodeGen -> simulator UI tests -> unsigned Release archive -> IPA -> structure/metadata verification -> upload.
4. When it is green, download the artifact named `CurrentSense-unsigned-ipa-b<run>-<commit>` from the run page. It contains the IPA and `release-report.md` (commit SHA, run number, test counts).
5. If a step is red, open the `logs-b<run>` artifact and fix the reported error before installing anything.

### Signing and installing

The IPA is **unsigned and cannot be installed directly**. Sign and sideload it with your own tool (for example iPASide) using your Apple ID. The bundle identifier `com.currentsense.app` may be rewritten by your signing tool; the app does not depend on it. Never commit certificates, profiles or passwords to the repository (the `.gitignore` excludes common signing files).

## Local development (macOS only, optional)

```
brew install xcodegen
cd Packages/CurrentSenseCore && swift test      # core tests; also runs on Linux/Windows toolchains
cd ../.. && xcodegen generate && open CurrentSense.xcodeproj
```

## Using the app

1. Choose **AC** or **DC** (top).
2. Tap the glass circle. The app takes a ~2 s background baseline: **hold the phone still and keep the load switched OFF** (DC).
3. DC: switch the load on. You see the field change in µT and signal quality. A current appears only if a method is set under *Current setup* **and** the signal is strong and steady; otherwise "Unavailable" with one instruction.
4. AC: hold the phone against the cable. You see Detected / Not detected, a Weak/Moderate/Strong category relative to the measured background, and signal quality. No number is ever shown.
5. Tap the circle again to stop. Results then show as "Last result" in a dimmed style.

If the phone moves or rotates after the baseline, DC readings are withheld (the baseline no longer applies). Stop and start again.

### Current setup (DC)

- **Off** (default): field change only.
- **Calibrated**: with a known current from a clamp meter, hold the phone where you will measure and tap *Calibrate*. Estimates are `field change / sensitivity`, valid only for that cable, position and orientation, and refused above 2x the calibrated current.
- **Ideal wire**: `I = 2*pi*r*B/mu0` for one long straight conductor at a distance you declare. Appliance cables carry opposing currents that largely cancel, so this is usually wrong by a large factor; it carries a minimum 30 % uncertainty and is refused above 50 %.

## Architecture

`Packages/CurrentSenseCore` (pure Foundation, fully unit-testable) holds the sample validation, baseline, DC/AC processors, estimator, quality rules, audio mapping, presenter and the `MeasurementPipeline` state machine. The app target holds the Core Motion source, the serial-queue `MeasurementEngine`, audio output, the view model and SwiftUI views. Sensor rate (up to ~100 Hz) and UI rate (10 Hz snapshots) are decoupled; the engine owns exactly one sensor subscription; stale snapshots from superseded sessions are dropped.

## Known limitations

See `docs/SCIENCE.md`. In short: thresholds are unvalidated on hardware; the actual magnetometer rate/filtering on iPhone 15 is unmeasured; at 100 Hz sampling a 50 Hz tone sits at Nyquist and can be invisible depending on phase; aliased frequencies cannot be told apart; translation of the phone is not detected; the signal cannot be attributed to a specific conductor; no distance measurement exists.
