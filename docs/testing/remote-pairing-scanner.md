# Remote scanner needs ML Kit initialized (#802)

## Cause and scope

[Issue #802](https://github.com/ccch1mneyyy/dsh-Go/issues/802) reported a blank camera preview and failed gallery decoding despite granted camera permission, with `MlKitContext has not been initialized`. The Android manifest deliberately removes `MlKitInitProvider` so disabled local OCR cannot initialize ML Kit at process startup. The barcode scanner needs that shared SDK, but only an admitted OCR job used to initialize it.

Remote now prepares ML Kit through `dsh/app.initializeBarcodeScanner` before mounting `MobileScanner`. `app/lib/remote/url/barcode_scanner.dart` is the one caller-side owner of that step; `app/lib/ui/remote/url_scan_page.dart` mounts the scanner only after it reports ready, and shows the unavailable line when it does not. OCR and the scanner share a synchronized, process-wide initialization gate: success is reused, a failed attempt is not retried because the SDK may have partially initialized global state. Preparation errors return `scanner_initialization_failed` without native exception details.

The provider stays disabled. App startup, settings reads and disabled OCR requests do not initialize ML Kit. Opening the scanner is a separate on-demand use of the shared SDK; it does not enable local OCR or create a text recognizer. Camera permission is still handled by Android/mobile_scanner, and a denied permission has its own line so it is not reported as a broken camera.

Regression to avoid: the initialization call was attached to the deleted pairing page and disappeared with it, while the manifest kept the provider removed. The call now belongs to the scanner module, not to a page.

## Automated coverage

- `app/test/remote/barcode_scanner_test.dart`: the channel method is called; a host that cannot initialize reports false; a platform without the channel is treated as usable (iOS, ArkTS host).
- `MlKitInitializationTest`: scanner/OCR initialization in either order and on reopen, concurrent callers, sticky failure. The callback gate is real production code, not an alternative initialization algorithm.
- `LocalOcrBoundaryTest`: existing no-request/privacy-denial, cancellation/deadline, result budget and failure-is-not-success protections.

```sh
(cd app && flutter pub get && flutter analyze)
(cd app && flutter test --no-pub test/remote/barcode_scanner_test.dart)
(cd app/android && gradle :app:testArm64DebugUnitTest)
python3 app/tool/l10n_merge.py --check
python3 app/tool/guide_sync.py --check
git diff --check
```

## Required real-device verification

Use a test installation; do not test with real pairing secrets in recordings/logs.

1. Cold start with local OCR off and without having run phone control. Open the QR scanner and scan a fresh dsh-pocket QR. The camera preview must appear (not the unavailable line) and the host must be added and connected.
2. Cold start, deny camera permission, open the scanner: the denial line appears, not "cannot start". Grant the permission in system settings, reopen, and scan.
3. Exercise scanner -> enabled OCR and enabled OCR -> scanner in the same process. Neither order should throw `not initialized` or `already initialized`.
4. Leave the page while it is preparing and return: no late camera start or disposed-controller error.
5. Cover more than one OEM/Android version; automated tests do not establish device compatibility.

## HarmonyOS

mobile_scanner has no HarmonyOS implementation. `dsh/app.scanQrCode` (Scan Kit through `AppLinksPlugin.ets`) still exists, but the current QR page has no Dart caller for it, so on HarmonyOS the page shows the unavailable line. Wiring the system scan page back in is a separate change; it needs its own device check.
