import 'dart:math';

import 'package:flutter/material.dart';

import 'equipment.dart';
import 'figure_spec.dart';
import 'skeleton.dart';

const _figureStroke = 10.0;
const _floorStroke = 2.0;

class ExerciseFigure extends StatelessWidget {
  const ExerciseFigure({super.key, required this.placement});

  final FigurePlacement placement;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 1,
      child: CustomPaint(
        painter: FigurePainter(
          placement: placement,
          figureColor: colors.primary,
          equipmentColor: colors.onSurfaceVariant,
          floorColor: colors.outlineVariant,
        ),
      ),
    );
  }
}

class FigurePainter extends CustomPainter {
  FigurePainter({
    required this.placement,
    required this.figureColor,
    required this.equipmentColor,
    required this.floorColor,
  });

  final FigurePlacement placement;
  final Color figureColor;
  final Color equipmentColor;
  final Color floorColor;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = min(size.width / figureCanvasSize.width, size.height / figureCanvasSize.height);
    canvas.translate(
      (size.width - figureCanvasSize.width * scale) / 2,
      (size.height - figureCanvasSize.height * scale) / 2,
    );
    canvas.scale(scale);
    _paintFloor(canvas);
    for (final item in placement.spec.equipment) {
      _paintEquipment(canvas, item);
    }
    _paintFigure(canvas, placement.joints);
  }

  void _paintFloor(Canvas canvas) {
    canvas.drawLine(
      const Offset(20, figureFloorY),
      const Offset(190, figureFloorY),
      _stroke(floorColor, _floorStroke),
    );
  }

  void _paintEquipment(Canvas canvas, Equipment item) {
    final stroke = _stroke(equipmentColor, item.width);
    switch (item) {
      case EquipmentLine():
        canvas.drawLine(placement.resolve(item.from), placement.resolve(item.to), stroke);
      case EquipmentPolyline():
        canvas.drawPath(_pathThrough(item.points.map(placement.resolve).toList()), stroke);
      case EquipmentCircle():
        canvas.drawCircle(
          placement.resolve(item.centre),
          item.radius,
          item.filled ? _fill(equipmentColor) : stroke,
        );
      case EquipmentRoundRect():
        final rect = RRect.fromRectAndRadius(
          Rect.fromPoints(placement.resolve(item.corner), placement.resolve(item.oppositeCorner)),
          Radius.circular(item.radius),
        );
        canvas.drawRRect(rect, item.filled ? _fill(equipmentColor) : stroke);
    }
  }

  void _paintFigure(Canvas canvas, FigureJoints joints) {
    final stroke = _stroke(figureColor, _figureStroke);
    canvas.drawLine(joints.hip, joints.shoulder, stroke);
    for (var i = 0; i < joints.legs.length; i++) {
      final leg = joints.legs[i];
      canvas.drawPath(_pathThrough([joints.legRoots[i], leg.knee, leg.ankle, leg.toe]), stroke);
    }
    for (var i = 0; i < joints.arms.length; i++) {
      final arm = joints.arms[i];
      canvas.drawPath(_pathThrough([joints.armRoots[i], arm.elbow, arm.wrist]), stroke);
    }
    canvas.drawCircle(joints.headCentre, headRadius, _fill(figureColor));
  }

  Path _pathThrough(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    return path;
  }

  Paint _stroke(Color color, double width) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  Paint _fill(Color color) => Paint()..color = color;

  @override
  bool shouldRepaint(FigurePainter old) =>
      old.placement != placement ||
      old.figureColor != figureColor ||
      old.equipmentColor != equipmentColor ||
      old.floorColor != floorColor;
}
