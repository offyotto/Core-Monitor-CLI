# Core-Monitor-CLI

`Core-Monitor-CLI` is a Swift macOS CLI for system monitoring and privileged fan control. The privilege boundary follows Apple's `SMJobBless` model:

- the CLI stays unprivileged
- all AppleSMC access lives in the helper
- the helper is installed into `/Library/PrivilegedHelperTools/`
- launchd owns the Mach service in `/Library/LaunchDaemons/`
- the first privileged install goes through `SMJobBless`

This repo is intentionally CLI-first. The helper install is hosted by a tiny bundled app because `SMJobBless` requires an app bundle with `SMPrivilegedExecutables`.

## Project Layout

```text
Core-Monitor-CLI/
├── Package.swift
├── Sources/
│   ├── CoreMonitorCLI/
│   │   └── main.swift
│   ├── CoreMonitorKit/
│   │   ├── Fan/
│   │   ├── Helper/
│   │   ├── Monitoring/
│   │   ├── SMC/
│   │   └── Support/
│   ├── CoreMonitorIPC/
│   │   └── SMCHelperXPC.swift
│   ├── CoreMonitorHelper/
│   │   └── main.swift
│   └── CoreMonitorBlessHost/
│       └── main.swift
├── Support/
│   ├── CodeSign/
│   └── SMJobBless/
├── BuildSupport/
│   └── Generated/
├── Scripts/
│   ├── render-smjobbless-plists.sh
│   ├── build-dist.sh
│   ├── notarize.sh
│   └── smoke-test.sh
├── Formula/
│   └── core-monitor-cli.rb
├── install.sh
└── config/
    └── example-curve.json
```

## Architecture

### Binaries

- `core-monitor`
  - user-facing CLI
  - talks to the privileged helper over XPC
  - never touches AppleSMC directly
- `core-monitor-helper`
  - privileged helper executable
  - embeds `__info_plist` and `__launchd_plist` sections for `SMJobBless`
  - installs as `ventaphobia.smc-helper`
- `core-monitor-bless-host`
  - tiny executable that lives inside `CoreMonitorBlessHost.app`
  - exists only so `SMJobBless` has a proper app bundle caller with `SMPrivilegedExecutables`

### Runtime Flow

1. `core-monitor` needs fan or thermal data.
2. The CLI connects to the Mach service `ventaphobia.smc-helper`.
3. If the helper is missing, the CLI launches `CoreMonitorBlessHost.app/Contents/MacOS/core-monitor-bless-host install`.
4. `core-monitor-bless-host` calls `SMJobBless(...)`.
5. launchd installs the helper and starts the Mach service.
6. The CLI retries the XPC call.

### Security Model

- `SMJobBless` is the only privilege-escalation path.
- The helper authorizes both:
  - `CoreTools.Core-Monitor-CLI`
  - `CoreTools.Core-Monitor-CLI.BlessHost`
- The helper validates connecting clients against `SMAuthorizedClients` before accepting XPC connections.
- The helper exposes only:
  - `readValue`
  - `setFanManual`
  - `setFanAuto`
  - optional lease/reset methods for safer automation
- Automated fan modes use helper-side leases so a crashed client does not leave temperature-driven overrides stuck forever.

## Commands

```bash
core-monitor status
core-monitor status --json
core-monitor status --watch 2

core-monitor fans list
core-monitor fans auto --fan 0
core-monitor fans auto --all
core-monitor fans set --fan 0 --rpm 2800
core-monitor fans set --fan 0 --rpm 2800 --lease 15
core-monitor fans mode smart --watch 2
core-monitor fans mode curve --file ./config/example-curve.json --watch 2

core-monitor sensors read FNum
core-monitor helper install
core-monitor helper status
core-monitor doctor
```

## Development Build

`swift build` works directly because placeholder SMJobBless plists are checked into `BuildSupport/Generated/`.

```bash
./Scripts/render-smjobbless-plists.sh
swift build
./.build/debug/core-monitor doctor
./.build/debug/core-monitor-helper read F0Mn
```

## Local Validation Performed Here

These checks were run in this workspace on April 14, 2026:

- `swift build`
  - passed
- `./.build/debug/core-monitor-helper read F0Mn`
  - returned `1199.0`
- `./.build/debug/core-monitor-helper read F0Mx`
  - returned `7199.0`
- unsigned debug CLI against the currently installed helper
  - failed with XPC communication denied, which is expected because the installed helper only authorizes the older signed app identifier
- a temporary CLI copy signed as `CoreTools.Core-Monitor`
  - connected successfully to the currently installed helper
- controlled write cycle through the existing privileged helper
  - set fan 0 to `2800 RPM`
  - verified `F0Tg` became `2800.0` with the new helper parser
  - restored fan 0 to automatic mode
- missing-helper simulation using env overrides
  - returned `Bless host bundle not found. Install the support bundle first or set CORE_MONITOR_BLESS_HOST.`
- `Scripts/build-dist.sh` with both Apple Development and Developer ID identities
  - produced signed release artifacts
- `spctl --assess`
  - rejected the Developer ID-signed artifacts as `Unnotarized Developer ID`, which is the expected pre-notarization state

## Build A Signed Release

Use the machine's real signing identity and team id:

```bash
TEAM_ID=6VDP675K4L \
VERSION=0.1.0 \
BUILD_NUMBER=1 \
SIGNING_IDENTITY='Developer ID Application: offyotto (6VDP675K4L)' \
./Scripts/build-dist.sh
```

That produces:

- `dist/core-monitor-cli-0.1.0.tar.gz`
- `dist/core-monitor-cli-0.1.0.zip`
- `dist/stage/bin/core-monitor`
- `dist/stage/libexec/CoreMonitorBlessHost.app`

## Notarization

Store credentials once on the release machine:

```bash
xcrun notarytool store-credentials core-monitor-notary \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID" \
  --password "YOUR_APP_SPECIFIC_PASSWORD"
```

Then notarize:

```bash
VERSION=0.1.0 \
NOTARY_PROFILE=core-monitor-notary \
./Scripts/notarize.sh
```

Equivalent raw commands:

```bash
xcrun notarytool submit dist/core-monitor-cli-0.1.0.zip \
  --keychain-profile core-monitor-notary \
  --wait

xcrun stapler staple dist/stage/libexec/CoreMonitorBlessHost.app
spctl --assess --type execute --verbose dist/stage/libexec/CoreMonitorBlessHost.app
spctl --assess --type exec --verbose dist/stage/bin/core-monitor
```

## Homebrew Release Model

`SMJobBless` cannot be shipped as a source-built Homebrew formula because end users do not have the vendor signing identity required to create a valid blessed helper. The formula in `Formula/core-monitor-cli.rb` intentionally installs the prebuilt signed release artifact instead.

Release flow:

1. Run `Scripts/build-dist.sh` with your Developer ID identity.
2. Run `Scripts/notarize.sh`.
3. Upload `dist/core-monitor-cli-<version>.tar.gz` to the GitHub release.
4. Compute the SHA:

```bash
shasum -a 256 dist/core-monitor-cli-0.1.0.tar.gz
```

5. Update `Formula/core-monitor-cli.rb` with the real release URL and SHA.

End users install with:

```bash
brew install core-monitor-cli
core-monitor helper install
```

## Curl Installer

The included `install.sh` is meant to be published from a stable URL:

```bash
curl -fsSL https://raw.githubusercontent.com/offyotto-sl3/Core-Monitor-CLI/main/install.sh | bash
```

It:

- fetches the latest GitHub release tarball
- installs `core-monitor` into `~/.local/bin`
- installs `CoreMonitorBlessHost.app` into `~/.local/share/core-monitor-cli`
- triggers `core-monitor helper install`
- prints final helper status

Override targets if needed:

```bash
BIN_DIR=/usr/local/bin \
SUPPORT_DIR=/usr/local/lib/core-monitor-cli \
bash install.sh
```

## Fresh-Machine Checklist

1. Download the notarized release artifact.
2. Install the CLI binary and `CoreMonitorBlessHost.app`.
3. Run `core-monitor helper install`.
4. Approve the administrator prompt.
5. Verify:

```bash
core-monitor helper status
core-monitor fans list
core-monitor sensors read FNum
```

Expected result:

- helper installed: `yes`
- XPC reachable: `yes`
- fan and sensor commands succeed without `sudo`

## Known Constraints

- The currently installed helper on this machine authorizes `CoreTools.Core-Monitor`, not the new CLI identifier, so the unsigned debug CLI cannot talk to that preexisting daemon. That is a local test-environment mismatch, not a package-structure issue.
- `SMJobBless` is deprecated as of macOS 13.0, but it remains the requested Apple-sanctioned workflow for privileged helper installation and is implemented here exactly for that reason.
- Notarization was prepared and validated up to the credential boundary. A stored `notarytool` profile was not present on this machine, so the final submission step was not executed here.
