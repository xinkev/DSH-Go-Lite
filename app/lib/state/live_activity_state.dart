// Live activity is retired with the pet layer: nothing is pushed to
// `dsh/notify`, and the native side keeps its own lifecycle.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../notify/live_activity.dart';
import 'android_features.dart';
import 'notify_state.dart';

export '../notify/live_activity.dart';

/// What the live activity shows now: nothing (the feature is retired).
final liveActivityProvider = Provider<LiveActivity?>((ref) => null);

/// What `dsh/notify` is told: always off.
final livePushProvider = Provider<LivePush>((ref) => const LivePush(enabled: false));

/// Kept for callers that watch it: nothing is pushed.
final liveActivityBridgeProvider = Provider<void>((ref) {
  ref.listen<LivePush>(livePushProvider, (previous, next) {}, fireImmediately: true);
});

/// What the phone offers; re-read with `ref.invalidate` when the app comes back.
final liveSystemStatusProvider = FutureProvider<LiveSystemStatus>(
  (ref) => ref.watch(notifyChannelProvider).liveStatus(),
);
