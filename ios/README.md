# PullScan for iPhone

SwiftUI + AVFoundation + Core ML port of the Android app, with the same features:
on-device recognition, the card lock with auto-add, ✓/✕ one-handed buttons, the
candidate picker, collection with estimated prices and rate-limited refresh, and
CSV zip export/import. Backups are interchangeable with the Android app.

- `PullScanCore/`: platform-independent logic (Swift package): card lock, preprocessing
  (PIL-compatible resize), index search, Core ML embedder, prices, backup/zip/CSV.
  Mirrors the Android classes of the same names.
- `PullScan/`: the app (camera, screens, storage).
- The card list, index and price snapshot are taken from `android/app/src/main/assets/`
  at build time, so both apps always ship the same data.

## Build

```sh
scripts/fetch_models.sh --ios          # Core ML model -> ios/PullScan/Model/ (from the release)
cd ios
cp Local.xcconfig.example Local.xcconfig   # set DEVELOPMENT_TEAM to run on a device
xcodegen                                # brew install xcodegen; generates PullScan.xcodeproj
open PullScan.xcodeproj
```

Requires Xcode 16+, iOS 17+, iPhone only, portrait.

## Test

```sh
cd ios/PullScanCore && swift test
```

Runs on the Mac. The parity test checks that Swift resize + Core ML give the same
embedding as the Python pipeline and the right top-1 card. It uses the Android parity
fixtures (`ml/export_android.py`, not in the repo) and the model, and is skipped
without them.
