# CurrentSense — iPhone Magnetic Current Research Prototype

CurrentSense is an experimental iOS app scaffold for investigating whether the built-in iPhone magnetometer can detect magnetic-field changes around a current-carrying wire.

## Important limitations

- This is a research prototype, not a certified current meter.
- The current estimate is only a simplified theoretical estimate for a long, straight, isolated wire with known sensor-to-wire distance and known field geometry.
- AC current at 50/60 Hz may not be reconstructable from Core Motion magnetometer samples. The app reports observed sample timing and must not be assumed to measure AC RMS current.
- Do not use this app to verify electrical safety or measure exposed mains wiring. Test only with an isolated, low-voltage, current-limited source and a reference ammeter.

## Open in Xcode

1. On a Mac with Xcode installed, unzip the archive.
2. Open `CurrentSense.xcodeproj`.
3. Select an iPhone 15 or another physical iPhone as the run destination.
4. Set a unique Bundle Identifier under Signing & Capabilities.
5. Select your Apple development team if required, then Build and Run.
6. Grant motion/magnetometer access if iOS prompts for it.

A Mac with Xcode is required to build and install a native iOS app. This archive does not contain a compiled IPA.

## What is included

- Live raw magnetic field components (µT) via Core Motion.
- Live magnitude and a simple scrolling time-series chart.
- Baseline capture and change-from-baseline display.
- Experimental DC current estimate from entered distance.
- AC observation mode with sample interval / effective rate diagnostics.
- CSV export through the iOS share sheet.

## Interpretation

`CMMagnetometerData.magneticField` provides the calibrated magnetic field in microteslas. The app records the data provided by Core Motion; it does not claim that the values are raw ADC sensor output or that the app controls the sensor's internal sample rate.

For a long, straight wire:
    B = μ0 I / (2πr)
so:
    I = 2πrB / μ0

The prototype estimates current using the magnitude of the difference between the current field vector and the captured baseline vector. This is valid only if the field geometry is understood and other magnetic sources are negligible. The app labels the result as an experimental estimate.

## Suggested first experiment

1. Place the phone on a non-magnetic, stable support, with the same orientation throughout.
2. Keep magnets, speakers, magnetic cases, and ferromagnetic objects away from the setup.
3. Capture baseline with current switched off.
4. Use an isolated, low-voltage DC supply and a straight wire; measure current with a reference ammeter.
5. Record a few current levels and distances; export CSV.
6. Repeat each point several times. Do not calibrate and validate on exactly the same readings.
7. For AC, inspect the CSV timestamps and field signal before making any RMS claims.
