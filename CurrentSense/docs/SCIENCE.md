# Scientific assumptions and limitations

## 1. What the iPhone provides
- Core Motion `startMagnetometerUpdates` delivers the **raw** field in microtesla in the device frame, with timestamps (seconds since boot). Raw data includes the phone's own hard-iron offset, so it is not zero in a "clean" place.
- Requested interval: 10 ms (100 Hz). The delivered rate and any internal filtering on iPhone 15 are **unknown until measured**. The app computes the effective rate from timestamps (median interval) and refuses to run below 20 Hz.
- No Hall current sensor exists. No distance sensor is usable for cable distance. Nothing here claims otherwise.
- Attitude/rotation rate come from device motion with `xArbitraryZVertical` (gyro + accelerometer, no magnetometer), so magnetic disturbance cannot corrupt the orientation check.

## 2. Baseline and vector processing
- Baseline = per-axis **median** of ~2 s of still samples (robust to outliers); noise = MAD-based sigma, floored at 0.05 uT (assumed quantisation guard, unmeasured). Rejected if sigma > 1.5 uT, if first-half/second-half medians differ by > 1 uT, if the rate is < 20 Hz, or if rotation > 0.35 rad/s occurs (acquisition restarts).
- DC delta is the **vector** difference `sample - baseline`; magnitudes are taken afterwards. A unit test shows the scalar difference of magnitudes would be wrong by ~0.35 uT for a 3 uT delta on a 45 uT background.
- The baseline is in the device frame and contains Earth + phone offset. Rotating the phone changes both differently, which cannot be separated without a full magnetometer calibration. The app therefore **invalidates the baseline when attitude changes by > 8 deg** (rather than guess a transform), and after 300 s. Without attitude data, DC confidence is capped at "Moderate".
- The baseline is **never adapted** during measurement, so a real slow signal is not erased. Consequence: the baseline must be taken with the load off, and slow environmental drift is not compensated (only bounded by the 300 s age limit).

## 3. DC current estimate
- Ideal long straight wire: `B = mu0 I / (2 pi r)`, `I = 2 pi r B / mu0` (known-answer tests: 10 A at 1 cm = 200 uT).
- A phase+neutral appliance cable has near-cancelling fields; B can be orders of magnitude below the single-wire value and depends on conductor spacing, twist and orientation. **One magnetometer cannot determine current and distance together.** Hence the estimate is produced only with (a) a calibration against a reference current at a repeatable position, or (b) an explicit user-declared ideal-wire geometry with >= 30 % model uncertainty.
- Gating (all must hold): no motion/orientation/baseline issue; SNR >= 10; relative spread of |delta| over 1 s <= 5 %; combined relative uncertainty <= 50 %; estimate <= 2x calibrated current; valid geometry. Otherwise "Unavailable".
- Direction/sign of current is not reported. A nearby permanent magnet or ferrous object moved during the measurement is indistinguishable from a current; "signal quality" does not mean the signal belongs to the target conductor, and is not accuracy.
- Calibration uncertainty = max(5 %, sqrt(repeatability^2 + 3 %^2)); the 3 % is an assumed clamp-meter tolerance. Single-point, assumes linearity.

## 4. AC detection
- Chain: 2nd-order high-pass (8 Hz, or 0.1*fs if lower) -> 1 s RMS -> ratio to the quiet-baseline noise floor measured through the same filter -> Schmitt trigger (enter 2.0 for 0.3 s, exit 1.5 for 0.5 s) -> categories at ratio 4 and 10 with 10 % hysteresis. Output is relative, not calibrated.
- It detects **AC-band magnetic activity above ~8 Hz** (including vibration of nearby magnets, motors, etc.), not specifically mains.
- **Sampling/aliasing.** At fs = 100 Hz: a 60 Hz tone aliases to 40 Hz (detectable); a 50 Hz tone lands exactly on Nyquist and its apparent amplitude is `A*|sin(phase)|`, so it can be invisible (tested, documented blind spot); 140 Hz also aliases to 40 Hz and is indistinguishable from 60 Hz (tested). A mains-tone check (single-frequency projection with real timestamps, +/-1 Hz scan, 1 s window, fraction >= 0.35) is reported only as **supporting evidence** for confidence; frequencies near DC or Nyquist are marked unresolvable. Whether the real sensor low-pass filters before decimation (attenuating 50/60 Hz) is unknown.
- Motion: rotation > 0.5 rad/s suppresses AC output with a 0.5 s hold-off. Linear hand movement is not observable (accelerometer unused); the 8 Hz second-order high-pass attenuates slow sway (1.5 Hz, 5 uT -> ratio ~1.3 in the prototype), but shaking at 5-15 Hz can leak through.
- Prototype numbers (Python, white Gaussian noise 0.1 uT/axis, fs 100): noise floor 0.082 uT; 60 Hz at 0.2 / 0.7 / 2 / 8 uT -> ratio 1.35 / 3.5 / 9.8 / 39; noise-only worst ratio over 200 x 20 s = 1.22 (threshold 2.0). Real sensor noise is probably not white or stationary; **thresholds are provisional until measured on device.**

## 5. What has and has not been validated
Validated: algorithm behaviour on synthetic data in a Python prototype (executed). Written but not executed: all Swift tests. Not done: any physical-device test, rate measurement, reference-meter comparison, CPU/battery profiling, long-session and orientation tests. The first things to measure on a real iPhone 15: delivered magnetometer rate and jitter, quiet-state noise sigma, and whether a known 50/60 Hz source produces a stable response.
