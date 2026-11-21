// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../common/pressable.dart';

import 'shapes.dart';
import 'surfaces.dart';

/// Flat surface:**不透明填充 + 发丝描边 + 外投影**。
///
/// 曾经是"模糊背后的内容"的玻璃;模糊与顶边高光已移除,层级、圆角、
/// 描边与投影的约定不变,调用方无需改动。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    this.tier = GlassTier.card,
    this.borderRadius,
    this.circle = false,
    this.stadium = false,
    this.padding,
    this.blur,
    this.grouped = false,
    this.settled,
    this.style,
    this.onTap,
    this.onLongPress,
    this.child,
  }) : assert(!(circle && stadium), 'circle 与 stadium 只能二选一' /* l10n:keep developer-only assertion */);

  final GlassTier tier;
  final BorderRadiusGeometry? borderRadius;
  final bool circle;
  final bool stadium;
  final EdgeInsetsGeometry? padding;

  /// 保留字段:不再有模糊,取值不影响渲染。
  final bool? blur;

  /// 保留字段:不再采样背景,取值不影响渲染。
  final bool grouped;

  /// 保留字段:不再有过渡中的模糊,取值不影响渲染。
  final double? settled;

  final GlassStyle? style;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? child;

  BorderRadiusGeometry get _radius =>
      borderRadius ??
      switch (tier) {
        GlassTier.chrome || GlassTier.sheet => AppShape.radiusXl,
        GlassTier.card => AppShape.radiusMd,
        GlassTier.pill => AppShape.radiusLg,
      };

  bool get _isStadium => stadium || (!circle && borderRadius == null && tier == GlassTier.pill);

  ShapeBorder get _shape {
    if (circle) return const CircleBorder();
    if (_isStadium) return const StadiumBorder();
    return RoundedSuperellipseBorder(borderRadius: _radius);
  }

  @override
  Widget build(BuildContext context) {
    final surfaces = DshSurfaces.of(context);
    final s = style ?? surfaces.glass(tier);
    final shape = _shape;
    final textDirection = Directionality.maybeOf(context);
    // 实色:兜底填充叠在页面底色上,形状后面不会透出滚动内容。
    final fill = Color.alphaBlend(s.fallbackFill, surfaces.backdropBottom);

    Widget content = child ?? const SizedBox.shrink();
    if (padding != null) content = Padding(padding: padding!, child: content);
    if (onTap != null || onLongPress != null) {
      content = Material(
        type: MaterialType.transparency,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          onLongPress: onLongPress,
          child: Pressable(behavior: HitTestBehavior.translucent, child: content),
        ),
      );
    }

    content = CustomPaint(
      foregroundPainter: _EdgePainter(
        shape: shape,
        hairline: s.hairline,
        hairlineWidth: s.hairlineWidth,
        textDirection: textDirection,
      ),
      child: DecoratedBox(
        decoration: ShapeDecoration(shape: shape, color: fill),
        child: content,
      ),
    );

    if (s.shadows.isNotEmpty) {
      content = CustomPaint(
        painter: _ShadowPainter(shape: shape, shadows: s.shadows, textDirection: textDirection),
        child: content,
      );
    }
    return content;
  }
}

/// 发丝描边。描边画在形状内侧,裁剪时不会被切掉一半。
class _EdgePainter extends CustomPainter {
  _EdgePainter({
    required this.shape,
    required this.hairline,
    required this.hairlineWidth,
    required this.textDirection,
  });

  final ShapeBorder shape;
  final Color hairline;
  final double hairlineWidth;
  final TextDirection? textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || hairline.a <= 0) return;
    final rect = Offset.zero & size;
    final width = math.max(hairlineWidth, 0.5);
    final path = shape.getOuterPath(rect.deflate(width / 2), textDirection: textDirection);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = hairline,
    );
  }

  @override
  bool shouldRepaint(_EdgePainter old) =>
      old.shape != shape || old.hairline != hairline || old.hairlineWidth != hairlineWidth || old.textDirection != textDirection;
}

/// 只在形状外部画的投影。
class _ShadowPainter extends CustomPainter {
  _ShadowPainter({required this.shape, required this.shadows, required this.textDirection});

  final ShapeBorder shape;
  final List<BoxShadow> shadows;
  final TextDirection? textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    var extent = 0.0;
    for (final s in shadows) {
      extent = math.max(extent, s.blurRadius * 2 + s.spreadRadius.abs() + s.offset.distance);
    }
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(rect.inflate(extent + 2))
      ..addPath(shape.getOuterPath(rect, textDirection: textDirection), Offset.zero);
    canvas.save();
    canvas.clipPath(outside);
    for (final s in shadows) {
      canvas.drawPath(
        shape.getOuterPath(rect.shift(s.offset).inflate(s.spreadRadius), textDirection: textDirection),
        s.toPaint(),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ShadowPainter old) =>
      old.shape != shape || !_sameShadows(old.shadows, shadows) || old.textDirection != textDirection;

  static bool _sameShadows(List<BoxShadow> a, List<BoxShadow> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Kept for call sites: a panel that used to fade its blur in once it settled.
class SlidingGlass extends StatelessWidget {
  const SlidingGlass({super.key, required this.motion, required this.tier, required this.borderRadius, this.child});

  final Animation<double> motion;
  final GlassTier tier;
  final BorderRadiusGeometry borderRadius;
  final Widget? child;

  @override
  Widget build(BuildContext context) => GlassSurface(tier: tier, borderRadius: borderRadius, child: child);
}

/// Kept for call sites: chrome floating over a web page, which used to drop its blur
/// because a backdrop filter cannot see a native view.
class GlassOverNativeView extends StatelessWidget {
  const GlassOverNativeView({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
