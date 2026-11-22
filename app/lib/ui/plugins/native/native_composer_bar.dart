// What sits between the conversation and the composer for plugins and ui.json —
// a plugin's status line, then the capsule row. Both give the activity strip
// its place while a reply generates; with neither, nothing is laid out at all.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../plugins/native/native_state.dart';
import 'composer_capsules.dart';
import 'composer_strip.dart';
import 'native_capability_scope.dart';

class NativeComposerBar extends ConsumerStatefulWidget {
  const NativeComposerBar({
    super.key,
    required this.sessionId,
    required this.visible,
    this.leading,
    this.strip = true,
  });

  /// The conversation on screen; null on the new-chat screen.
  final String? sessionId;

  /// False while a reply generates.
  final bool visible;

  /// The chat's own pills, pinned at the capsule row's start ([ComposerCapsuleRow.leading]).
  final Widget? leading;

  /// Draws the status line too; false where it is a card of the chat's dock
  /// deck instead (`DockStack`).
  final bool strip;

  @override
  ConsumerState<NativeComposerBar> createState() => _NativeComposerBarState();
}

class _NativeComposerBarState extends ConsumerState<NativeComposerBar> {
  @override
  void didUpdateWidget(NativeComposerBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A reply ended: the agent may have installed or switched a plugin.
    if (!oldWidget.visible && widget.visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) rereadNativeContributions(ref);
      });
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
