import 'package:dsh_app/state/chat_state.dart' show SendMode;
import 'package:dsh_app/state/send_mode_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a picked send mode is kept for the next launch', () async {
    final first = ProviderContainer();
    addTearDown(first.dispose);
    await first.read(sendModeProvider.notifier).set(SendMode.queue);
    expect(first.read(sendModeProvider), SendMode.queue);

    final second = ProviderContainer();
    addTearDown(second.dispose);
    second.read(sendModeProvider);
    await Future<void>.delayed(Duration.zero);
    expect(second.read(sendModeProvider), SendMode.queue);
  });

  test('without a stored choice the send button keeps 发送', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sendModeProvider);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(sendModeProvider), SendMode.now);
  });
}
