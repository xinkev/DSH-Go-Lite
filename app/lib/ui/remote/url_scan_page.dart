// Pairing by QR: scan a dsh-pocket / dsh web QR and add it as a direct URL
// host. The code is an https URL that carries the access PIN as `?token=`;
// the token is stored as the Pocket PIN and as the engine launch token so
// both gates (pocket's cookie and dsh web's own login) work from one scan.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../l10n/l10n.dart';
import '../../remote/url/barcode_scanner.dart';
import '../../remote/url/pocket_auth.dart';
import '../../state/hosts_state.dart';
import '../theme/theme.dart';

class UrlScanPage extends ConsumerStatefulWidget {
  const UrlScanPage({super.key});

  static Route<UrlHostConfig> route() => MaterialPageRoute<UrlHostConfig>(builder: (_) => const UrlScanPage());

  @override
  ConsumerState<UrlScanPage> createState() => _UrlScanPageState();
}

class _UrlScanPageState extends ConsumerState<UrlScanPage> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);

  /// Null until the host reports whether the scanner SDK is usable; false means
  /// the camera cannot run on this build (see [_prepareScanner]).
  bool? _scannerReady;
  bool _handled = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_prepareScanner());
  }

  /// ML Kit is not initialized at app launch, so the scanner is mounted only
  /// after the host has initialized it; its camera start needs that SDK.
  Future<void> _prepareScanner() async {
    final ready = await ensureBarcodeScannerReady();
    if (!mounted) return;
    setState(() => _scannerReady = ready);
  }

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled || _saving) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null || raw.trim().isEmpty) return;
    _handled = true;
    final l10n = context.l10n;
    ParsedUrlHost parsed;
    try {
      parsed = parseUrlHost(raw);
    } on UrlHostFormatException {
      setState(() => _error = l10n.remoteScanQrInvalid);
      _handled = false;
      return;
    }
    // The QR carries only the address: dsh-pocket keeps the PIN on the computer.
    // A dsh web QR carries its own `?token=`, which then serves as both the
    // pocket PIN and the engine token.
    var pin = parsed.launchToken;
    String? pocketCookie;
    try {
      if (pin == null && await PocketAuth.needsPin(parsed.baseUri)) {
        final signedIn = await _askPin(parsed.baseUri);
        if (signedIn == null) {
          _handled = false;
          return;
        }
        pin = signedIn.pin;
        pocketCookie = signedIn.cookie;
      }
    } on PocketLoginException catch (failure) {
      if (!mounted) return;
      setState(() => _error = failure.retryable ? l10n.remoteUrlErrUnreachable : l10n.remoteScanPinWrong);
      _handled = false;
      return;
    }
    if (!mounted) return;
    final config = UrlHostConfig(id: UrlHostConfig.newId(), name: parsed.baseUri.host, baseUri: parsed.baseUri);
    setState(() => _saving = true);
    await ref.read(hostsProvider.notifier).saveUrl(
      config,
      secrets: UrlHostSecrets(launchToken: parsed.launchToken, pocketPin: pin, pocketCookie: pocketCookie),
    );
    await _controller.stop();
    if (!mounted) return;
    Navigator.of(context).pop(config);
  }

  /// Asks for the pocket PIN until it signs in, or the person gives up.
  ///
  /// A wrong PIN reopens the dialog with the reason; a locked or unreachable
  /// host gives up, so the page can say what happened.
  Future<({String pin, String cookie})?> _askPin(Uri baseUri) async {
    String? error;
    while (true) {
      if (!mounted) return null;
      final entered = await showDialog<String>(context: context, builder: (_) => _PinDialog(error: error));
      if (entered == null || entered.isEmpty) return null;
      try {
        final cookie = await PocketAuth.login(baseUri, entered);
        return (pin: entered, cookie: cookie);
      } on PocketLoginException catch (failure) {
        if (failure.retryable || !mounted) rethrow;
        error = failure.reason == PocketLoginReason.locked
            ? context.l10n.remoteScanPinLocked
            : context.l10n.remoteScanPinWrong;
      }
    }
    return null;
  }

  Widget _message(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final preview = switch (_scannerReady) {
      null => const Center(child: CircularProgressIndicator()),
      false => _message(l10n.remoteScanQrUnavailable),
      true => MobileScanner(
        controller: _controller,
        onDetect: (capture) => unawaited(_onDetect(capture)),
        errorBuilder: (context, error) => _message(
          error.errorCode == MobileScannerErrorCode.permissionDenied
              ? l10n.remoteScanQrPermissionDenied
              : l10n.remoteScanQrUnavailable,
        ),
      ),
    };
    return Scaffold(
      appBar: AppBar(title: Text(l10n.remoteScanQr)),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: ClipRRect(borderRadius: AppShape.radiusLg, child: preview)),
            const SizedBox(height: 12),
            Text(l10n.remoteScanQrHint, textAlign: TextAlign.center),
            if (_error case final error?) ...[
              const SizedBox(height: 8),
              Text(error, textAlign: TextAlign.center, style: TextStyle(color: DshColors.of(context).danger)),
            ],
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// The pocket access PIN, typed once and verified before the host is saved.
class _PinDialog extends StatefulWidget {
  const _PinDialog({this.error});

  final String? error;

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.remoteScanPinTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.remoteScanPinHint),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            decoration: InputDecoration(labelText: l10n.remoteUrlPocketPin, errorText: widget.error),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
        FilledButton(onPressed: _submit, child: Text(l10n.remoteScanPinConnect)),
      ],
    );
  }
}

