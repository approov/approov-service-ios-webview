#!/bin/bash
set -euo pipefail

task_repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$task_repo"
task_artifacts=${APPROOV_TEST_ARTIFACTS_DIR:-"$task_repo/.build/simulator-results"}
task_derived=${APPROOV_TEST_BUILD_DIR:-"$task_repo/.build/simulator-derived"}
task_packages=${APPROOV_TEST_PACKAGES_DIR:-"$task_repo/.build/source-packages"}
mkdir -p "$task_artifacts"
task_run=$(mktemp -d "$task_artifacts/run.XXXXXX")
task_simulator=${1:-}

if [[ -z "$task_simulator" ]]; then
    xcrun simctl list devices available --json > "$task_run/devices.json"
    task_simulator=$(python3 - "$task_run/devices.json" <<'PY'
import json, re, sys
devices = json.load(open(sys.argv[1]))['devices']
runtimes = sorted((key for key in devices if '.iOS-' in key),
                  key=lambda key: tuple(int(x) for x in re.findall(r'\d+', key)), reverse=True)
for runtime in runtimes:
    phones = [x for x in devices[runtime] if x.get('isAvailable') and x['name'].startswith('iPhone')]
    if phones:
        print(phones[0]['udid'])
        break
else:
    raise SystemExit('No available iPhone simulator. Install an iOS runtime in Xcode.')
PY
)
fi

# A booted device reports an error from boot; bootstatus checks either outcome.
xcrun simctl boot "$task_simulator" 2>/dev/null || true
xcrun simctl bootstatus "$task_simulator" -b
task_arguments=(
    -scheme approov-service-ios-webview
    -destination "platform=iOS Simulator,id=$task_simulator"
    -clonedSourcePackagesDirPath "$task_packages"
    -derivedDataPath "$task_derived"
)

xcodebuild "${task_arguments[@]}" -resolvePackageDependencies > "$task_run/resolve.log" 2>&1
xcodebuild "${task_arguments[@]}" -disableAutomaticPackageResolution -skipPackageUpdates \
    build-for-testing > "$task_run/build.log" 2>&1

# SPM's binary SDK copy can lack a simulator-loadable signature. Sign only the
# generated build product, never the dependency checkout or a distribution SDK.
task_sdk="$task_derived/Build/Products/Debug-iphonesimulator/Approov.framework"
if [[ -d "$task_sdk" ]]; then
    codesign --force --sign - "$task_sdk"
fi

task_exit=0
xcodebuild "${task_arguments[@]}" -disableAutomaticPackageResolution -skipPackageUpdates \
    -resultBundlePath "$task_run/tests.xcresult" test-without-building \
    > "$task_run/test.log" 2>&1 || task_exit=$?
python3 - "$task_run" <<'PY'
from pathlib import Path
import sys
run = Path(sys.argv[1])
print('Test evidence:', run)
for line in (run/'test.log').read_text(errors='replace').splitlines():
    if 'Executed ' in line or '** TEST' in line or 'error: -[' in line:
        print(line)
PY
exit "$task_exit"
