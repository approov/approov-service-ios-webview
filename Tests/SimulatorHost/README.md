# Simulator test host

This harness runs the existing WebView tests inside a normal UIKit application.
It requires Xcode 16 or later and an iOS simulator with iOS 17 or later.
The library's deployment requirement remains iOS 15 in `Package.swift`.

The app creates a scene, window, and empty view controller.
It performs no Approov initialization or WebKit warm-up.
The two hosted XCTest targets reference the existing test folders and local Swift package.
The suite contains 195 regression tests and two host-environment checks.

Xcode synchronized folders automatically include new files in the existing test folders.
The package remains responsible for library builds, dependencies, and resources.
The host's local networking exception supports the controlled loopback HTTP fixtures.

## Run

From the repository root:

```sh
bash Scripts/test-simulator.sh
# Or select an available iOS 17+ simulator explicitly:
bash Scripts/test-simulator.sh SIMULATOR_UDID
```

The script resolves dependencies, builds the hosted tests, and runs them with bounded test timeouts.
It stores logs and the result bundle under `.build/simulator-results/run.*`.
The existing `APPROOV_TEST_ARTIFACTS_DIR`, `APPROOV_TEST_BUILD_DIR`, and `APPROOV_TEST_PACKAGES_DIR` overrides remain available.

Xcode performs normal ad-hoc simulator signing with `CODE_SIGNING_ALLOWED=YES` and `CODE_SIGN_IDENTITY=-`.
It signs the app, test bundles, and embedded frameworks through its standard phases.
No development team, provisioning profile, keychain change, or manual SDK signing step is required.

## Maintain

The generated project and shared `WebViewHostedTests` scheme are checked in.
CI can use them directly without installing a project generator.
`project.yml` records the project specification.
To regenerate it with XcodeGen 2.46.0:

```sh
xcodegen generate --spec Tests/SimulatorHost/project.yml --project Tests/SimulatorHost
```

Keep the workspace's resolved dependency pins aligned with the package's `Package.resolved` when updating dependencies.
Do not add library code, customer configuration, or session cookies to the host app.
