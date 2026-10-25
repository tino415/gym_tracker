import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'body_regions.dart';

class MuscleMap extends StatelessWidget {
  const MuscleMap({super.key, required this.highlighted});

  final Set<String> highlighted;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: bodyViewSize.width * BodyView.values.length / bodyViewSize.height,
      child: CustomPaint(
        painter: MuscleMapPainter(
          lit: regionsOf(highlighted),
          bodyColor: colors.surfaceContainerHighest,
          unlitColor: colors.outlineVariant,
          litColor: colors.primary,
        ),
      ),
    );
  }
}

class MuscleMapPainter extends CustomPainter {
  MuscleMapPainter({
    required this.lit,
    required this.bodyColor,
    required this.unlitColor,
    required this.litColor,
  });

  final Set<BodyRegion> lit;
  final Color bodyColor;
  final Color unlitColor;
  final Color litColor;

  @override
  void paint(Canvas canvas, Size size) {
    final content = Size(bodyViewSize.width * BodyView.values.length, bodyViewSize.height);
    final scale = min(size.width / content.width, size.height / content.height);
    canvas.translate(
      (size.width - content.width * scale) / 2,
      (size.height - content.height * scale) / 2,
    );
    canvas.scale(scale);
    for (final view in BodyView.values) {
      canvas.save();
      canvas.translate(bodyViewSize.width * view.index, 0);
      _paintView(canvas, view);
      canvas.restore();
    }
  }

  void _paintView(Canvas canvas, BodyView view) {
    for (final shape in silhouette) {
      _fill(canvas, shape, bodyColor);
    }
    for (final region in BodyRegion.values.where((r) => r.view == view)) {
      _fill(canvas, region.shape, lit.contains(region) ? litColor : unlitColor);
    }
  }

  void _fill(Canvas canvas, RegionShape shape, Color color) {
    final paint = Paint()..color = color;
    for (final rect in shape.rects()) {
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(MuscleMapPainter old) =>
      !setEquals(old.lit, lit) ||
      old.bodyColor != bodyColor ||
      old.unlitColor != unlitColor ||
      old.litColor != litColor;
}
