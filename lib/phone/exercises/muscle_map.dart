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
    final scale = size.height / bodyViewSize.height;
    final contentWidth = bodyViewSize.width * BodyView.values.length * scale;
    canvas.translate((size.width - contentWidth) / 2, 0);
    canvas.scale(scale);
    for (final view in BodyView.values) {
      canvas.save();
      canvas.translate(bodyViewSize.width * view.index, 0);
      _paintView(canvas, view);
      canvas.restore();
    }
  }

  void _paintView(Canvas canvas, BodyView view) {
    _fill(canvas, silhouette, bodyColor);
    for (final region in BodyRegion.values.where((r) => r.view == view)) {
      _fill(canvas, [region.shape], lit.contains(region) ? litColor : unlitColor);
    }
  }

  void _fill(Canvas canvas, List<RegionShape> shapes, Color color) {
    final paint = Paint()..color = color;
    for (final shape in shapes) {
      for (final rect in shape.rects()) {
        canvas.drawRRect(rect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(MuscleMapPainter old) =>
      !_sameRegions(old.lit, lit) ||
      old.bodyColor != bodyColor ||
      old.unlitColor != unlitColor ||
      old.litColor != litColor;

  bool _sameRegions(Set<BodyRegion> a, Set<BodyRegion> b) =>
      a.length == b.length && a.containsAll(b);
}

class ExerciseThumbnail extends StatelessWidget {
  const ExerciseThumbnail({super.key, required this.muscleSyncIds});

  static const size = 44.0;

  final Set<String> muscleSyncIds;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Center(child: MuscleMap(highlighted: muscleSyncIds)),
        ),
      ),
    );
  }
}
