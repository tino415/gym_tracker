import 'dart:ui';

import '../equipment.dart';
import '../figure_spec.dart';
import '../skeleton.dart';
import 'gym_kit.dart';

final conditioningFigures = <String, FigurePlacement>{
  'ba0e059b-ed5e-4e6d-b8d2-599c5c2f74b4': FigurePlacement(_burpees),
  'b985b9f8-f4c6-463c-8997-c56fe61ea1a8': FigurePlacement(_jumpingJacks),
  'ff2c5a32-8386-45ac-b57c-8d4e48a708d9': FigurePlacement(_marchInPlace),
  '60803563-d74d-422a-9185-e84b870259d5': FigurePlacement(_mountainClimbers),
  '8101da57-2748-4f85-92aa-7552df161c84': FigurePlacement(_rowingMachine),
  '01da3032-d625-4506-bcdc-0a2b40f9db09': FigurePlacement(_stationaryBike),
};

const _straightArm = ArmAngles(upper: 90, fore: 90);
const _plankLeg = LegAngles(thigh: 161, shin: 161, foot: 75);

final _burpees = FigureSpec(
  pose: Pose.fromWrist(
    const Offset(150, onFloorY),
    torso: -19,
    head: -19,
    arms: const [_straightArm],
    legs: const [_plankLeg],
  ),
);

const _jumpingJacks = FigureSpec(
  pose: Pose(
    hip: Offset(100, 130.6),
    torso: -90,
    head: -90,
    arms: [ArmAngles(upper: -125, fore: -125), ArmAngles(upper: -55, fore: -55)],
    legs: [
      LegAngles(thigh: 115, shin: 115, foot: 180),
      LegAngles(thigh: 65, shin: 65, foot: 0),
    ],
  ),
);

final _marchInPlace = FigureSpec(
  pose: Pose.fromAnkle(
    const Offset(95, onFloorY),
    torso: -90,
    head: -90,
    arms: const [ArmAngles(upper: 50, fore: -50)],
    legs: const [
      LegAngles(thigh: 90, shin: 90, foot: 0),
      LegAngles(thigh: 0, shin: 90, foot: 0),
    ],
    inProfile: true,
  ),
);

final _mountainClimbers = FigureSpec(
  pose: Pose.fromWrist(
    const Offset(150, onFloorY),
    torso: -19,
    head: -19,
    arms: const [_straightArm],
    legs: const [
      _plankLeg,
      LegAngles(thigh: 25, shin: 170, foot: 70),
    ],
    inProfile: true,
  ),
);

final _rowingMachine = FigureSpec(
  pose: const Pose(
    hip: Offset(60, 152),
    torso: -105,
    head: -105,
    arms: [ArmAngles(upper: 110, fore: -5)],
    legs: [LegAngles(thigh: 3, shin: 3, foot: -80)],
  ),
  equipment: [
    EquipmentLine(point(30, 165), point(150, 165)),
    post(40, 165),
    post(140, 165),
    EquipmentRoundRect(point(45, 158), point(78, 165), filled: true),
    EquipmentLine(point(127, 165), point(127, 138), width: 5),
    EquipmentCircle(point(158, 135), 20),
    post(158, 155),
    EquipmentLine(hand, point(140, 130), width: 2),
  ],
);

final _stationaryBike = FigureSpec(
  pose: const Pose(
    hip: Offset(85, 100),
    torso: -80,
    head: -75,
    arms: [ArmAngles(upper: 40, fore: 0)],
    legs: [LegAngles(thigh: 75, shin: 95, foot: 5)],
  ),
  equipment: [
    EquipmentRoundRect(point(70, 106), point(102, 112), filled: true),
    EquipmentLine(point(86, 112), point(98, 150)),
    EquipmentCircle(point(98, 150), 16),
    EquipmentLine(point(98, 150), const Anchor.at(Joint.ankle, dx: 8, dy: 5)),
    EquipmentLine(const Anchor.at(Joint.ankle, dx: 2, dy: 7), const Anchor.at(Joint.ankle, dx: 16, dy: 7), width: 4),
    EquipmentLine(point(98, 150), point(150, 165)),
    EquipmentCircle(point(150, 165), 18),
    EquipmentLine(point(150, 165), hand.shifted(4, 0)),
    EquipmentLine(hand.shifted(-6, 0), hand.shifted(10, 0), width: 5, inFront: true),
    EquipmentLine(point(70, figureFloorY), point(170, figureFloorY), width: 5),
    EquipmentLine(point(98, 166), point(98, figureFloorY)),
  ],
);
