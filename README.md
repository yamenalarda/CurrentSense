# CurrentSense

CurrentSense is an iPhone magnetometer research app. The repository contains the earlier source tree; a separate workflow can build the prepared source archive supplied for this build.

## Build the prepared source archive with GitHub Actions

1. Download the prepared `CurrentSense-source.zip` from the ChatGPT conversation.
2. In this repository, choose **Add file → Upload files** and upload the ZIP to the repository root. Keep the exact filename `CurrentSense-source.zip`, then commit the upload to `main`.
3. Open **Actions → Build uploaded CurrentSense source (iOS IPA)**. The workflow starts when the ZIP is added. It runs the core Swift tests, generates the Xcode project, runs UI tests in an iPhone simulator, archives Release, packages the IPA, verifies the package, and uploads an artifact.
4. Download **CurrentSense-iPhone-unsigned-IPA-…** from the successful workflow run. The logs and test report are also uploaded as artifacts.

## Important installation limitation

GitHub Actions creates an **unsigned** iOS IPA because signing requires an Apple provisioning profile and signing identity. The unsigned IPA cannot be installed directly on an iPhone. On Windows, use a trusted sideloading tool to sign it with your Apple ID. Do not place Apple ID credentials, signing certificates, or provisioning profiles in this repository.

CI testing is not physical-device validation. CurrentSense's AC mode indicates magnetic-field activity; it is not a certified voltage detector. Current estimates depend on measurement geometry and calibration and must not be used for electrical safety decisions.
