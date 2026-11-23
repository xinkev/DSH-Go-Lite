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
import '../../remote/url/url_host_config.dart';
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
    final token = parsed.launchToken;
    final config = UrlHostConfig(id: UrlHostConfig.newId(), name: parsed.baseUri.host, baseUri: parsed.baseUri);
    setState(() => _saving = true);
    await ref.read(hostsProvider.notifier).saveUrl(
      config,
      secrets: UrlHostSecrets(launchToken: token, pocketPin: token),
    );
    if (!mounted) return;
    await _controller.stop();
    Navigator.of(context).pop(config);
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
