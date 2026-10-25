import 'dart:ui';

import 'equipment.dart';
import 'figure_spec.dart';
import 'skeleton.dart';

FigurePlacement? figureFor(String? exerciseId) => figurePlacements[exerciseId];

const _trxLowRowId = '8b5aa84c-1d92-406c-9408-3652376d239e';
const _backSquatId = 'c6beb1bd-0529-47c6-9494-7167a8ecce36';
const _seatedLateralRaiseId = 'b56c9b50-a840-41b9-9bb7-772fe02f10fe';

final figurePlacements = <String, FigurePlacement>{
  _trxLowRowId: FigurePlacement(_trxLowRow),
  _backSquatId: FigurePlacement(_backSquat),
  _seatedLateralRaiseId: FigurePlacement(_seatedLateralRaise),
};

const _trxLowRow = FigureSpec(
  pose: Pose(
    hip: Offset(90, 133),
    torso: -120,
    head: -119,
    arms: [ArmAngles(upper: 95, fore: -38)],
    legs: [LegAngles(thigh: 60, shin: 60, foot: -36)],
  ),
  equipment: [
    EquipmentLine(Anchor.canvas(160, 14), Anchor.canvas(190, 14)),
    EquipmentLine(Anchor.canvas(175, 14), Anchor.canvas(175, 22)),
    EquipmentLine(Anchor.canvas(175, 22), Anchor.at(Joint.wrist)),
    EquipmentLine(
      Anchor.at(Joint.wrist, dx: -5, dy: -6),
      Anchor.at(Joint.wrist, dx: 7, dy: 5),
      width: 5,
    ),
  ],
);

const _backSquat = FigureSpec(
  pose: Pose(
    hip: Offset(81, 150),
    torso: -65,
    head: -75,
    arms: [ArmAngles(upper: 125, fore: -70)],
    legs: [LegAngles(thigh: 10, shin: 100, foot: -5)],
  ),
  equipment: [
    EquipmentCircle(Anchor.at(Joint.shoulder, dx: -4, dy: -4), 14),
    EquipmentCircle(Anchor.at(Joint.shoulder, dx: -4, dy: -4), 6, filled: true),
  ],
);

const _seatedLateralRaise = FigureSpec(
  pose: Pose(
    hip: Offset(100, 145),
    torso: -90,
    head: -90,
    arms: [ArmAngles(upper: 175, fore: 172), ArmAngles(upper: 5, fore: 8)],
    legs: [
      LegAngles(thigh: 160, shin: 95, foot: 175),
      LegAngles(thigh: 20, shin: 85, foot: 5),
    ],
  ),
  equipment: [
    EquipmentRoundRect(
      Anchor.at(Joint.hip, dx: -26, dy: 8),
      Anchor.at(Joint.hip, dx: 26, dy: 14),
    ),
    EquipmentLine(Anchor.at(Joint.hip, dx: 0, dy: 14), Anchor.canvas(100, 190)),
    EquipmentLine(Anchor.canvas(80, 190), Anchor.canvas(120, 190)),
    EquipmentRoundRect(
      Anchor.at(Joint.wrist, dx: -4, dy: -6),
      Anchor.at(Joint.wrist, dx: 4, dy: 6),
      filled: true,
    ),
    EquipmentRoundRect(
      Anchor.at(Joint.wrist, limb: 1, dx: -4, dy: -6),
      Anchor.at(Joint.wrist, limb: 1, dx: 4, dy: 6),
      filled: true,
    ),
  ],
);
