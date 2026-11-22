import 'package:flutter/material.dart';

import '../common/smooth_size.dart';
import '../theme/theme.dart';

/// A host form's bottom bar: its actions stay put above the page (and above
/// the keyboard), over a soft fade of the page background.
class HostFormBar extends StatelessWidget {
  const HostFormBar({super.key, required this.children});

  final List<Widget> children;

  /// Room to leave at the end of the page so nothing hides under the bar.
  static const height = 88.0;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom > 0 ? 0.0 : MediaQuery.viewPaddingOf(context).bottom;
    final base = DshSurfaces.of(context).backdropBottom;
    // The page fades out above the keys; under them the bar is solid, so
    // nothing scrolls through a tonal or disabled fill.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [base.withValues(alpha: 0), base],
            ),
          ),
          child: const SizedBox(height: 24),
        ),
        ColoredBox(
          color: base,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + bottom),
            child: Row(children: children),
          ),
        ),
      ],
    );
  }
}

/// [AnimatedSize] unless animations are off (a zero-duration AnimatedSize
/// re-dirties itself during layout).
class HostFormReveal extends StatelessWidget {
  const HostFormReveal({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.of(context, AppMotion.standard);
    if (duration == Duration.zero) return child;
    return SmoothSize(duration: duration, curve: AppMotion.std, alignment: Alignment.topCenter, child: child);
  }
}
