import 'dart:ui';

import '../equipment.dart';
import '../figure_spec.dart';
import '../skeleton.dart';
import 'gym_kit.dart';

final coreFigures = <String, FigurePlacement>{
  '32399f22-834d-446b-9eb4-2e88cd78667d': FigurePlacement(_plank),
  '91daa723-8970-4fed-b4f8-8d06046be9dc': FigurePlacement(_sidePlank),
  'fda828ad-1e71-4217-af8e-3fc46d636614': FigurePlacement(_sidePlank),
  '8338c91d-8ae9-4b51-bac7-10bf7c489052': FigurePlacement(_sidePlank, mirrored: true),
  '698c4ab0-8a4c-41bc-b66e-fa796fff166c': FigurePlacement(_hangingLegRaise),
  '65ea24ae-3b5d-4262-97ec-48d36052b94d': FigurePlacement(_captainsChairLegRaise),
  '287817a2-c38a-4b89-91a0-e0dfe46b4df5': FigurePlacement(_reverseCrunch),
  '772e735b-3f30-4669-853d-dcf6ead81b22': FigurePlacement(_weightedDeclineSitUp),
  '831e5949-dbe6-4181-99d2-289ccc43fd9c': FigurePlacement(_deadBug),
};

const _straightLegForward = LegAngles(thigh: 0, shin: 0, foot: -60);

final _plank = FigureSpec(
  pose: Pose.fromWrist(
    const Offset(164, onFloorY),
    torso: -6,
    head: -6,
    arms: const [ArmAngles(upper: 90, fore: 0)],
    legs: const [LegAngles(thigh: 174, shin: 174, foot: 70)],
  ),
);

final _sidePlank = FigureSpec(
  pose: Pose.fromWrist(
    const Offset(164, onFloorY),
    torso: -6,
    head: -6,
    arms: const [
      ArmAngles(upper: 90, fore: 0),
      ArmAngles(upper: 215, fore: 150),
    ],
    legs: const [LegAngles(thigh: 174, shin: 174, foot: 70)],
    inProfile: true,
  ),
);

final _hangingLegRaise = FigureSpec(
  pose: Pose.fromWrist(
    const Offset(108, 24),
    torso: -88,
    head: -105,
    arms: const [ArmAngles(upper: -75, fore: -75)],
    legs: const [_straightLegForward],
  ),
  equipment: overheadBar(108, 24, uprightX: 186),
);

final _captainsChairLegRaise = FigureSpec(
  pose: const Pose(
    hip: Offset(75, 132),
    torso: -90,
    head: -90,
    arms: [ArmAngles(upper: 90, fore: 0)],
    legs: [_straightLegForward],
  ),
  equipment: [
    pad(point(62, 150), point(62, 70)),
    EquipmentRoundRect(point(62, 114), point(112, 121), filled: true),
    post(56, 70),
    EquipmentLine(point(36, figureFloorY), point(110, figureFloorY), width: 5),
  ],
);

final _reverseCrunch = FigureSpec(
  pose: const Pose(
    hip: Offset(105, 170),
    torso: 161,
    head: 195,
    arms: [ArmAngles(upper: 5, fore: 0)],
    legs: [LegAngles(thigh: -115, shin: 20, foot: -50)],
  ),
);

final _weightedDeclineSitUp = FigureSpec(
  pose: const Pose(
    hip: Offset(85, 135),
    torso: -90,
    head: -90,
    arms: [ArmAngles(upper: 60, fore: -60)],
    legs: [LegAngles(thigh: -25, shin: 30, foot: -50)],
  ),
  equipment: [
    pad(point(52, 160), point(116, 130)),
    EquipmentLine(point(86, 144), point(86, figureFloorY)),
    EquipmentLine(point(114, 131), point(150, figureFloorY)),
    EquipmentCircle(const Anchor.at(Joint.ankle, dx: -3, dy: -11), 6, filled: true, inFront: true),
    EquipmentLine(const Anchor.at(Joint.ankle, dx: -3, dy: -11), point(120, 128)),
    barbell(const Anchor.at(Joint.shoulder, dx: 14, dy: 14)),
  ],
);

final _deadBug = FigureSpec(
  pose: const Pose(
    hip: Offset(112, 180),
    torso: 180,
    head: 188,
    arms: [ArmAngles(upper: -90, fore: -90)],
    legs: [LegAngles(thigh: -90, shin: 0, foot: -75)],
  ),
);
