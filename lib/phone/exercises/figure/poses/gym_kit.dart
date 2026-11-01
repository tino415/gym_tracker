import 'dart:math';
import 'dart:ui';

import '../equipment.dart';
import '../skeleton.dart';

/// The y of a limb's centre line when its stroke rests on the floor.
const onFloorY = figureFloorY - 5;

/// The top of a flat bench, one shin plus a foot above the floor.
const benchTopY = 158.0;

/// The y of a body's centre line when it lies on a flat bench.
const onBenchY = benchTopY - 5;

const hand = Anchor.at(Joint.wrist);

const _plateRadius = 14.0;
const _thinBarRadius = 4.0;
const _endOnDumbbellRadius = 8.0;
const _kettlebellRadius = 8.0;
const _kettlebellHandleRadius = 4.0;
const _pulleyRadius = 5.0;
const _cableWidth = 2.0;
const _padWidth = 7.0;
const _benchPadHeight = 7.0;

Anchor point(double x, double y) => Anchor.canvas(x, y);

/// A barbell runs across the body, so from the side it is seen end-on: a plate.
Equipment barbell(Anchor centre) => EquipmentCircle(centre, _plateRadius, filled: true, inFront: true);

Equipment thinBar(Anchor centre) => EquipmentCircle(centre, _thinBarRadius, filled: true, inFront: true);

/// A dumbbell whose handle runs across the body, so from the side it is seen
/// end-on, like a barbell's plate but smaller.
Equipment endOnDumbbell(Anchor centre) =>
    EquipmentCircle(centre, _endOnDumbbellRadius, filled: true, inFront: true);

List<Equipment> kettlebell(Anchor grip) => [
      EquipmentCircle(grip, _kettlebellHandleRadius, inFront: true),
      EquipmentCircle(grip.shifted(0, _kettlebellHandleRadius + _kettlebellRadius - 1), _kettlebellRadius,
          filled: true, inFront: true),
    ];

List<Equipment> dumbbell(Anchor centre) => [
      EquipmentLine(centre.shifted(-8, 0), centre.shifted(8, 0), inFront: true),
      _dumbbellHead(centre.shifted(-10, 0)),
      _dumbbellHead(centre.shifted(10, 0)),
    ];

List<Equipment> uprightDumbbell(Anchor centre) => [
      EquipmentLine(centre.shifted(0, -8), centre.shifted(0, 8), inFront: true),
      _dumbbellHead(centre.shifted(0, -10), wide: true),
      _dumbbellHead(centre.shifted(0, 10), wide: true),
    ];

Equipment _dumbbellHead(Anchor centre, {bool wide = false}) {
  final (halfWidth, halfHeight) = wide ? (6.0, 3.0) : (3.0, 6.0);
  return EquipmentRoundRect(
    centre.shifted(-halfWidth, -halfHeight),
    centre.shifted(halfWidth, halfHeight),
    radius: 1,
    filled: true,
    inFront: true,
  );
}

List<Equipment> flatBench(double left, double right, {double top = benchTopY}) => [
      EquipmentRoundRect(point(left, top), point(right, top + _benchPadHeight)),
      post(left + 10, top + _benchPadHeight),
      post(right - 10, top + _benchPadHeight),
    ];

/// A vertical support from [top] down to the floor.
Equipment post(double x, double top) => EquipmentLine(point(x, top), point(x, figureFloorY));

/// A solid pad between two points, for an angled backrest or platform.
Equipment pad(Anchor from, Anchor to) => EquipmentLine(from, to, width: _padWidth);

List<Equipment> cable(Anchor handle, double pulleyX, double pulleyY) => [
      EquipmentLine(handle, point(pulleyX, pulleyY), width: _cableWidth),
      EquipmentCircle(point(pulleyX, pulleyY), _pulleyRadius),
    ];

Equipment strap(Anchor from, Anchor to) => EquipmentLine(from, to);

Equipment strapHandle(Anchor grip) => EquipmentLine(grip.shifted(-5, -6), grip.shifted(7, 5), width: 5);

/// A bar seen end-on at the end of an overhead arm carried by an upright.
List<Equipment> overheadBar(double barX, double barY, {double uprightX = 180}) => [
      post(uprightX, barY),
      EquipmentLine(point(barX, barY), point(uprightX, barY)),
      thinBar(point(barX, barY)),
    ];

List<Equipment> trxAnchor(double x, {double y = 14}) => [
      EquipmentLine(point(x - 15, y), point(x + 15, y)),
      EquipmentLine(point(x, y), point(x, y + 8)),
    ];

const _insetCentreX = 38.0;
const _insetCableEndY = 20.0;
const _gripWidth = 4.0;

/// The attachment on the cable, drawn apart in the top left corner, because a
/// side view shows every handle end-on.
List<Equipment> _handleInset(List<Equipment> handle) => [
      EquipmentRoundRect(point(12, 8), point(64, 46), width: 1.5),
      EquipmentLine(point(_insetCentreX, 8), point(_insetCentreX, _insetCableEndY), width: _cableWidth),
      ...handle,
    ];

List<Equipment> straightBarInset() => _handleInset([
      EquipmentLine(point(_insetCentreX, _insetCableEndY), point(_insetCentreX, 26), width: _cableWidth),
      EquipmentLine(point(19, 26), point(57, 26), width: _gripWidth),
    ]);

List<Equipment> vHandleInset() => _handleInset([
      EquipmentPolyline(
        [point(31, 38), point(_insetCentreX, _insetCableEndY), point(45, 38)],
        width: _cableWidth,
      ),
      EquipmentLine(point(31, 38), point(45, 38), width: _gripWidth),
    ]);

/// A MAG handle: a bar with two grips running along the cable, palms facing.
List<Equipment> magHandleInset({required double halfWidth}) => _handleInset([
      EquipmentLine(
        point(_insetCentreX - halfWidth, _insetCableEndY),
        point(_insetCentreX + halfWidth, _insetCableEndY),
        width: _cableWidth,
      ),
      for (final x in [_insetCentreX - halfWidth, _insetCentreX + halfWidth])
        EquipmentLine(point(x, _insetCableEndY), point(x, 36), width: _gripWidth),
    ]);

const _arrowStep = 6.0;
const _arrowHeadLength = 7.0;
const _arrowHeadSpreadDegrees = 150.0;

/// A movement arrow along a circle around [centre], from [fromDegrees] to [toDegrees].
List<Equipment> arcArrow(Offset centre, double radius, double fromDegrees, double toDegrees) {
  final direction = (toDegrees - fromDegrees).sign;
  final steps = ((toDegrees - fromDegrees).abs() / _arrowStep).ceil();
  Offset onCircle(double degrees) {
    final radians = degrees * pi / 180;
    return centre.translate(cos(radians) * radius, sin(radians) * radius);
  }

  final tip = onCircle(toDegrees);
  final heading = toDegrees + direction * 90;
  Anchor headEnd(double spread) {
    final radians = (heading + spread) * pi / 180;
    return point(tip.dx + cos(radians) * _arrowHeadLength, tip.dy + sin(radians) * _arrowHeadLength);
  }

  return [
    EquipmentPolyline([
      for (var i = 0; i <= steps; i++)
        () {
          final at = onCircle(fromDegrees + (toDegrees - fromDegrees) * i / steps);
          return point(at.dx, at.dy);
        }(),
    ], width: _cableWidth),
    EquipmentPolyline(
      [
        headEnd(_arrowHeadSpreadDegrees),
        point(tip.dx, tip.dy),
        headEnd(-_arrowHeadSpreadDegrees),
      ],
      width: _cableWidth,
    ),
  ];
}
