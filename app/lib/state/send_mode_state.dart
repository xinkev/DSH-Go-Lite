// How a message lands while a turn is already running: 发送 (auto: steer),
// 插话 (steer) or 排队 (queue). The long-press sheet on the send button sets
// it, and the choice is kept for later sends and later launches — picking
// 排队 once should not quietly go back to steering on the next message.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_state.dart' show SendMode;

class SendModeController extends Notifier<SendMode> {
  static const key = 'chat_send_mode';

  @override
  SendMode build() {
    unawaited(_load());
    return SendMode.now;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = SendMode.values.asNameMap()[prefs.getString(key)];
      // A choice made while reading back wins over the stored value.
      if (stored != null && state == SendMode.now) state = stored;
    } catch (_) {
      // No preferences backend (tests): keep 发送.
    }
  }

  Future<void> set(SendMode mode) async {
    state = mode;
    try {
      await (await SharedPreferences.getInstance()).setString(key, mode.name);
    } catch (_) {
      // Kept for this run only.
    }
  }
}

final sendModeProvider = NotifierProvider<SendModeController, SendMode>(SendModeController.new);
