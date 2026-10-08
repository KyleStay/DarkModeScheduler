#!/usr/bin/env bash
#
# Static boundary check for the default, background-safe verification lane.
# The live app still contains interactive APIs by design; this gate makes sure
# the fixture and commands that default verification actually runs do not.
set -euo pipefail

cd "$(dirname "$0")/.."

background_source="BackgroundVerification.swift"
for file in "$background_source" PresentationHostTests.swift PresentationHost.swift run-tests.sh Tools/verify-background.sh; do
    if [[ ! -f "$file" ]]; then
        echo "✗ background-safety boundary file is missing: $file" >&2
        exit 1
    fi
done

forbidden=(
    'MenuBarExtra'
    'NSStatusItem'
    'CGEvent'
    'activate('
    'orderFront'
    'makeKeyAndOrderFront'
    'makeMain'
    'NSWorkspace.shared.open'
    'SMAppService'
    'NSAppleScript'
    'requestWhenInUseAuthorization'
    'requestLocation()'
    'requestAuthorization('
    'UserDefaults.standard'
    'Process('
    'osascript'
)

for token in "${forbidden[@]}"; do
    if rg -n --fixed-strings "$token" "$background_source" PresentationHostTests.swift PresentationHost.swift run-tests.sh Tools/verify-background.sh; then
        echo "✗ forbidden background-test operation detected: $token" >&2
        exit 1
    fi
done

# The fixture reaches the model and service adapters transitively. Guard the
# exact initializer boundaries too, because scanning only the entry source
# would miss a live adapter constructed by AppModel or Services.
fixture_model="$(sed -n '/^    init(backgroundFixture fixture:/,/^    }$/p' AppModel.swift)"
live_model="$(sed -n '/^    init() {/,/^    }$/p' AppModel.swift)"
location_fixture="$(sed -n '/^    init(backgroundOnly: Bool)/,/^    }$/p' Services.swift)"
if [[ "$fixture_model" != *"locationService = LocationService(backgroundOnly: true)"* \
      || "$fixture_model" == *"locationService = LocationService()"* ]]; then
    echo "✗ background model initializer does not use the disabled location adapter" >&2
    exit 1
fi
if [[ "$live_model" != *"locationService = LocationService()"* ]]; then
    echo "✗ live model initializer does not use the real location adapter" >&2
    exit 1
fi
if [[ "$location_fixture" != *"manager = nil"* \
      || "$location_fixture" != *"geocoder = nil"* ]]; then
    echo "✗ background location adapter still constructs live CoreLocation state" >&2
    exit 1
fi

if rg -n --fixed-strings 'defaults ' run-tests.sh Tools/verify-background.sh; then
    echo "✗ forbidden defaults command detected in default verification" >&2
    exit 1
fi

background_line="$(rg -n '^if CommandLine\.arguments\.contains\("--background-fixture"\)' main.swift | cut -d: -f1)"
app_line="$(rg -n '^DarkModeSchedulerApp\.main\(\)' main.swift | cut -d: -f1)"
if [[ -z "$background_line" || -z "$app_line" || "$background_line" -ge "$app_line" ]]; then
    echo "✗ background fixture is not dispatched before the live app scene" >&2
    exit 1
fi

if rg -n --fixed-strings -- '--interactive-selftest' run-tests.sh Makefile Tools/verify-background.sh; then
    echo "✗ interactive self-test leaked into default verification" >&2
    exit 1
fi

echo "✅ Background-test safety boundary passed."
