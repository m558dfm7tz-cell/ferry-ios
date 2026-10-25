# Ferry (iOS test app)

Minimal iOS app that exists only to validate the build pipeline — a single
SwiftUI page showing the "Ferry" title and the app version. No features, no
networking, no signing.

- App name: `Ferry`
- Bundle id: `com.ferry.test`
- Deployment target: iOS 18.0
- Device family: iPhone (`TARGETED_DEVICE_FAMILY = 1`)
- Swift: 5.0
- No extensions, no entitlements, no App Groups, no test targets.

## Layout

```
Ferry/
  Ferry.xcodeproj/           hand-written project (objectVersion 56, explicit refs)
  Ferry/
    FerryApp.swift
    ContentView.swift
    Assets.xcassets/
      AppIcon.appiconset/    single 1024x1024 universal icon
      AccentColor.colorset/
tools/
  make-icon.ps1              generates the AppIcon.png (Windows PowerShell)
.github/workflows/build-ipa.yml
```

## Before building: generate the app icon

`Assets.xcassets/AppIcon.appiconset/Contents.json` references `AppIcon.png`,
which is produced by a script (it is not checked in as a binary in some setups,
so generate it before the first build):

```powershell
powershell -ExecutionPolicy Bypass -File tools\make-icon.ps1
```

The script reads `C:\temp\ferry-icons\plane3-R3-256.png`, draws it centered at
~70% size on an opaque `#0F172A` background, and writes the 1024x1024
`Ferry\Assets.xcassets\AppIcon.appiconset\AppIcon.png`. Commit the resulting
`AppIcon.png` so the CI workflow can build.

## Build locally (requires a Mac with Xcode)

```bash
xcodebuild -project Ferry/Ferry.xcodeproj \
  -scheme Ferry \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath build/Ferry.xcarchive \
  archive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

Package the unsigned IPA:

```bash
mkdir -p build/Payload
cp -R build/Ferry.xcarchive/Products/Applications/Ferry.app build/Payload/Ferry.app
cd build && zip -r -y Ferry-unsigned.ipa Payload
```

## Downloading the CI artifact

1. Open the repo on GitHub, go to **Actions**.
2. Pick the latest **Build IPA** run (triggered by a push to `main` or manually
   via **Run workflow**).
3. Scroll to **Artifacts** and download `Ferry-unsigned-ipa`.
4. Unzip it to get `Ferry-unsigned.ipa`.

## Sideloading with a free Apple ID (Sideloadly)

1. Install [Sideloadly](https://sideloadly.io/) on a Windows or macOS machine.
2. Connect the iPhone by USB (or enable Wi-Fi sync), trust the computer on the
   device.
3. Sign in to Sideloadly with a **free** Apple ID.
4. Drag `Ferry-unsigned.ipa` into Sideloadly, set the bundle id to
   `com.ferry.test` (Sideloadly may adjust it to your team, e.g.
   `com.ferry.test.yourname`), and click **Start**.
5. On the device, trust the developer certificate under
   **Settings → General → VPN & Device Management**.
6. Free-account apps expire after 7 days; reinstall (or refresh) before expiry.

## SIM-sticker phone cautions (important)

If this app is installed on a carrier/SIM-sticker device:

- **Never update iOS.** A system update can break the SIM-sticker activation,
  and restoring it usually requires redoing the activation with the sticker.
- **Decline every update prompt.** Tap "Later" / "Cancel" on iOS update dialogs
  and turn off automatic updates under **Settings → General → Software Update →
  Automatic Updates**.
- **Developer Mode reboot re-activates the sticker.** Enabling/using Developer
  Mode (required for free-account sideloads) forces a reboot; on a SIM-sticker
  phone that reboot can drop the sticker activation, so expect to redo the
  sticker activation afterward.
