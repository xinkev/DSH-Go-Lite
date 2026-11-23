// A project (workspace) row in the drawer list: its name, the number of
// conversations under it and a chevron that folds them away, as the official
// sidebar does. Tap the row to open or close.

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/motion.dart';
import '../../theme/theme.dart';
import 'session_tile.dart';

class DrawerProjectHeader extends StatelessWidget {
  const DrawerProjectHeader({
    super.key,
    required this.title,
    required this.count,
    required this.open,
    required this.onTap,
  });

  final String title;
  final int count;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Semantics(
      button: true,
      expanded: open,
      label: title,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          customBorder: Squircle.border(AppShape.md),
          child: SizedBox(
            height: SessionTile.height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Icon(AppIcons.workspace, size: 18, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurface),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('$count', style: AppType.tabular(theme.textTheme.labelSmall!).copyWith(color: colors.textTertiary)),
                  const SizedBox(width: 2),
                  AnimatedRotation(
                    turns: open ? 0 : -0.25,
                    duration: AppMotion.of(context, AppMotion.quick),
                    child: Icon(AppIcons.expand, size: 18, color: colors.textTertiary),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
