# CurrentSense developer guide

For app behaviour, safety notes, installation caveats, and user instructions, see the [repository homepage](../README.md).

## Source layout

- `CurrentSense/`: iOS app entry point, SwiftUI screens, view model, sensor source, measurement engine, and optional audio feedback.
- `Packages/CurrentSenseCore/`: Foundation-only measurement algorithms and regression tests.
- `CurrentSenseUITests/`: iPhone simulator UI tests using a synthetic sensor in Debug builds.
- `docs/SCIENCE.md`: numerical assumptions, AC sampling limitations, and validation requirements.
- `docs/archive/`: historical development artifacts; these are not part of the active build.
- `scripts/`: simulator selection and unsigned IPA packaging / verification helpers.
- `project.yml`: XcodeGen project declaration.

## Local checks (macOS with Xcode)

```bash
cd Packages/CurrentSenseCore
swift test
cd ../..
xcodegen generate
```

The app archive and UI tests use the repository's GitHub Actions workflow on a hosted macOS runner. See the **Actions** tab for the status of the latest source revision. CI produces an unsigned IPA; installing it on a real iPhone still requires signing.

## Layout rule

The screen background extends to the physical display edges, but interactive controls must remain inside SwiftUI's safe area. Do not put `.ignoresSafeArea(.all)` on the root content container: that moves the AC/DC selector into the Dynamic Island / camera region. The simulator UI test checks the selector's vertical position to prevent regression.
