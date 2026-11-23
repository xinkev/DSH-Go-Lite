import 'package:dsh_app/remote/url/barcode_scanner.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dsh/app');
  final methods = <String>[];
  PlatformException? failure;

  void answerCalls(Future<Object?> Function(MethodCall)? handler) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, handler);

  setUp(() {
    methods.clear();
    failure = null;
    answerCalls((call) async {
      methods.add(call.method);
      if (failure case final error?) throw error;
      return null;
    });
  });

  tearDown(() => answerCalls(null));

  test('initializes the host scanner SDK', () async {
    expect(await ensureBarcodeScannerReady(), isTrue);
    expect(methods, ['initializeBarcodeScanner']);
  });

  test('reports a host that cannot initialize the SDK', () async {
    failure = PlatformException(code: 'scanner_initialization_failed');

    expect(await ensureBarcodeScannerReady(), isFalse);
  });

  test('treats a platform without this channel as usable', () async {
    answerCalls(null);

    expect(await ensureBarcodeScannerReady(), isTrue);
  });
}
