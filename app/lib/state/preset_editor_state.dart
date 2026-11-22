// State behind the native Agent preset editor. The Host has no Remote that
// writes a preset: like the official creator entry, a new preset is handed to
// creator mode (`cordis`) in a new conversation, here with the exact bundle
// files to write and install.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';
import 'schedule_editor_state.dart';
import 'sessions_state.dart';

/// Creator mode is available: the `cordis` preset is listed and healthy.
bool creatorAvailable(List<AgentPresetInfo>? presets) =>
    presets?.any((p) => p.id == 'cordis' && p.broken == null) ?? false;

/// Opens a new conversation in creator mode and sends it [request]; returns
/// the conversation to show.
Future<String> startCreator(WidgetRef ref, String request, {required bool Function() isCurrent}) async {
  final conn = ref.read(activeConnectionProvider).value;
  if (conn == null) throw const DshClosedException('not connected');
  final id = await ref.read(sessionsProvider.notifier).createForConnection(conn, isCurrent: isCurrent);
  if (!isCurrent()) throw const DshClosedException('preset creation owner changed');
  await conn.client.selectAgentPreset(id, 'cordis');
  if (!isCurrent()) throw const DshClosedException('preset creation owner changed');
  await conn.client.prompt(id, request, timeZone: ref.read(deviceTimeZoneProvider).value);
  return id;
}
