// The Android host removes ML Kit's startup provider so the SDK is not loaded at
// launch. Barcode scanning needs that SDK, so this asks the host to initialize it
// before the camera starts; ui/remote/url_scan_page.dart calls it before mounting
// the scanner. The host keeps the process-wide gate: a success is reused and a
// failed attempt is not retried, because the SDK can leave global state behind.

import 'package:flutter/services.dart';

const _channel = MethodChannel('dsh/app');

/// Initializes the barcode scanner, or reports false when the host could not.
///
/// A false result stays false for this process; opening the scanner again does
/// not reinitialize the SDK.
Future<bool> ensureBarcodeScannerReady() async {
  try {
    await _channel.invokeMethod<void>('initializeBarcodeScanner');
  } on PlatformException {
    return false;
  } on MissingPluginException {
    // iOS and the ArkTS host carry no ML Kit; their camera needs no setup.
  }
  return true;
}
