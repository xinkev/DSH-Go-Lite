// 设置 › 主题:明暗(浅色 / 深色 / 跟随系统)。


import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/appearance_state.dart';
import '../../../state/settings_state.dart';
import '../../../ui_config/ui_config.dart';
import '../../common/pressable.dart';
import '../../shell/page_frame.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../settings_widgets.dart';

/// 设置首页「外观」组的第一行:当前配色的色点 + 名字 · 明暗,点开 [AppearancePage]。
class AppearanceEntryTile extends ConsumerWidget {
  const AppearanceEntryTile({super.key, this.tint = 0});

  /// The hub group's hue.
  final int tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final mode = switch (ref.watch(uiThemeModeProvider.select((s) => s.value))) {
      ThemeMode.light => l10n.commonLight,
      ThemeMode.dark => l10n.commonDark,
      ThemeMode.system => l10n.commonFollowSystem,
    };
    return SettingsTile(
      icon: AppIcons.theme,
      tint: tint,
      spot: SettingsIndex.entry(SettingsPageId.appearance),
      value: Text(mode),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AppearancePage())),
    );
  }
}

/// 设置 › 主题:只有明暗三档。
class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return AppPage.list(
      title: l10n.pluginsTheme,
      children: [
        SettingsSection(
          title: l10n.hubThemeLightDark,
          children: [SpotAnchor(spot: Spots.darkMode, child: const ThemeModePicker())],
        ),
      ],
    );
  }
}

/// The grid every picker on this page shares, with [TileStylePicker] and
/// [AppIconPicker]: content 16 from the card's edges, columns 12 apart, the
/// name 8 under its preview (or under its ring).
abstract final class PickerGrid {
  static const inset = 16.0;
  static const gap = 12.0;
  static const labelGap = 8.0;

  /// The name under a choice: the accent and heavier when chosen.
  static TextStyle labelStyle(BuildContext context, {required bool selected}) {
    final theme = Theme.of(context);
    return theme.textTheme.labelMedium!.copyWith(
      color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
    );
  }
}

// ── 外观模式 ─────────────────────────────────────────────────────────────

/// 三张小样:浅色、深色、跟随系统(左浅右深)。小样用当前配色画,换配色时
/// 跟着淡变;选中的那张外面一圈主色环。
class ThemeModePicker extends ConsumerWidget {
  const ThemeModePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final modes = [
      (ThemeMode.light, l10n.commonLight),
      (ThemeMode.dark, l10n.commonDark),
      (ThemeMode.system, l10n.commonFollowSystem),
    ];
    final mode = ref.watch(uiThemeModeProvider);
    final (light, dark) = _themesFor(ref.watch(accentProvider));
    // The ring sits outside each preview, in [_ModeTile.room]: the padding
    // and gap leave room for it, so previews land 16 from the card and 12
    // apart, column for column with the tile styles below.
    const room = _ModeTile.room;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PickerGrid.inset - room,
        PickerGrid.inset - room,
        PickerGrid.inset - room,
        PickerGrid.inset,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (mode.fromUiJson)
            const Padding(
              padding: EdgeInsets.only(left: room, right: room, bottom: 8),
              child: Align(alignment: Alignment.centerLeft, child: FromUiJsonBadge(UiSettingKey.themeMode)),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (i, (m, label)) in modes.indexed) ...[
                if (i > 0) const SizedBox(width: PickerGrid.gap - 2 * room),
                Expanded(
                  child: _ModeTile(
                    label: label,
                    selected: mode.value == m,
                    enabled: !mode.fromUiJson,
                    light: m == ThemeMode.dark ? null : light,
                    dark: m == ThemeMode.light ? null : dark,
                    onTap: () => unawaited(
                      ThemeRevealHost.run(context, () => ref.read(settingsProvider.notifier).setThemeMode(m)),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Light and dark themes of [accent], built once per palette.
(ThemeData, ThemeData) _themesFor(AppAccent accent) {
  final hit = _themeCache[accent];
  if (hit != null) return hit;
  if (_themeCache.length > 4) _themeCache.clear();
  return _themeCache[accent] = (buildLightTheme(accent: accent), buildDarkTheme(accent: accent));
}

final _themeCache = <AppAccent, (ThemeData, ThemeData)>{};

class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.enabled,
    this.light,
    this.dark,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool enabled;

  /// Null: that half isn't drawn ([dark] alone fills the tile).
  final ThemeData? light;
  final ThemeData? dark;

  /// Ring stroke and the gap between the ring and the preview.
  static const ring = 2.0;
  static const gap = 3.0;

  /// Room around the preview for the ring.
  static const room = ring + gap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quick = AppMotion.of(context, AppMotion.quick);
    final fade = AppMotion.of(context, AppMotion.standard);
    Widget preview(ThemeData? end) => end == null
        ? const SizedBox.shrink()
        : TweenAnimationBuilder<ThemeData>(
            tween: ThemeDataTween(end: end),
            duration: fade,
            curve: AppMotion.std,
            builder: (context, t, _) => CustomPaint(painter: _PhonePainter(t), size: Size.infinite),
          );
    final content = Column(
      children: [
        AspectRatio(
          aspectRatio: 0.8,
          child: CustomPaint(
            foregroundPainter: _RingPainter(
              color: scheme.primary.withValues(alpha: selected ? 1 : 0),
              width: ring,
              radius: AppShape.md + ring + gap,
            ),
            child: Padding(
              padding: const EdgeInsets.all(room),
              child: ClipRSuperellipse(
                key: ValueKey('theme-mode-$label'),
                borderRadius: AppShape.radiusMd,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (light != null) preview(light),
                    if (dark != null)
                      ClipRect(clipper: light == null ? null : const _RightHalf(), child: preview(dark)),
                    // Edge of the preview: a hairline, like a card.
                    DecoratedBox(
                      decoration: ShapeDecoration(
                        shape: RoundedSuperellipseBorder(
                          borderRadius: AppShape.radiusMd,
                          side: BorderSide(color: scheme.outlineVariant, width: 0.5),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: PickerGrid.labelGap - room),
        // A narrow column at a large text size: the name shrinks to fit
        // rather than losing its end.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: AnimatedDefaultTextStyle(
            duration: quick,
            style: PickerGrid.labelStyle(context, selected: selected),
            child: Text(label, textAlign: TextAlign.center, maxLines: 1),
          ),
        ),
      ],
    );
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: enabled ? onTap : null,
      child: Pressable(
        onTap: onTap,
        enabled: enabled,
        child: enabled ? content : Opacity(opacity: 0.5, child: content),
      ),
    );
  }
}

class _RightHalf extends CustomClipper<Rect> {
  const _RightHalf();

  @override
  Rect getClip(Size size) => Rect.fromLTWH(size.width / 2, 0, size.width / 2, size.height);

  @override
  bool shouldReclip(_RightHalf oldClipper) => false;
}

/// A ring just outside a rounded rect (the selected mode).
class _RingPainter extends CustomPainter {
  _RingPainter({required this.color, required this.width, required this.radius});

  final Color color;
  final double width;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a == 0) return;
    final rect = (Offset.zero & size).deflate(width / 2);
    canvas.drawRSuperellipse(
      RSuperellipse.fromRectAndRadius(rect, Radius.circular(radius - width / 2)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.color != color || old.width != width || old.radius != radius;
}

/// A tiny chat screen in [theme]: the page with its two glows, a header
/// capsule, two reply lines, the user's bubble and the composer with its
/// send key.
class _PhonePainter extends CustomPainter {
  _PhonePainter(this.theme);

  final ThemeData theme;

  @override
  void paint(Canvas canvas, Size size) {
    final s = theme.extension<DshSurfaces>()!;
    final scheme = theme.colorScheme;
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [s.backdropTop, s.backdropBottom],
        ).createShader(rect),
    );
    void glow(Offset c, double r, Color color) {
      final b = Rect.fromCircle(center: c, radius: r);
      canvas.drawRect(b, Paint()..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)]).createShader(b));
    }

    glow(Offset(w * 0.92, 0), h * 0.7, s.glowPrimary);
    glow(Offset(0, h), h * 0.62, s.glowSecondary);

    final glass = Paint()..color = s.chrome.fallbackFill;
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = s.chrome.hairline;
    final unit = w / 100;

    // Header capsule.
    final header = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(w / 2, 12 * unit), width: 44 * unit, height: 9 * unit),
      const Radius.circular(99),
    );
    canvas
      ..drawRRect(header, glass)
      ..drawRRect(header, edge);

    final ink = Paint()..color = scheme.onSurface.withValues(alpha: theme.brightness == Brightness.dark ? 0.26 : 0.2);
    RRect bar(double x, double y, double width, double height) =>
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y, width, height), Radius.circular(height / 2));

    // The user's bubble, then the reply under it.
    final bubble = RRect.fromRectAndRadius(
      Rect.fromLTWH(w - 12 * unit - 46 * unit, 30 * unit, 46 * unit, 15 * unit),
      Radius.circular(6 * unit),
    );
    canvas.drawRRect(bubble, Paint()..color = s.userBubble);
    canvas.drawRRect(bar(w - 12 * unit - 38 * unit, 35.5 * unit, 30 * unit, 4 * unit), ink);
    canvas.drawRRect(bar(12 * unit, 54 * unit, 66 * unit, 4.5 * unit), ink);
    canvas.drawRRect(bar(12 * unit, 63 * unit, 76 * unit, 4.5 * unit), ink);
    canvas.drawRRect(bar(12 * unit, 72 * unit, 48 * unit, 4.5 * unit), ink);

    // Composer with the send key: the one accent on the screen.
    final composerH = 15 * unit;
    final composer = RRect.fromRectAndRadius(
      Rect.fromLTWH(8 * unit, h - 8 * unit - composerH, w - 16 * unit, composerH),
      const Radius.circular(99),
    );
    canvas
      ..drawRRect(composer, glass)
      ..drawRRect(composer, edge);
    final send = composer.outerRect;
    canvas.drawCircle(
      Offset(send.right - send.height / 2, send.center.dy),
      send.height / 2 - 2.5 * unit,
      Paint()..color = scheme.primary,
    );
  }

  @override
  bool shouldRepaint(_PhonePainter old) => old.theme != theme;
}

