import 'dart:ui';

import '../equipment.dart';
import '../figure_spec.dart';
import '../skeleton.dart';
import 'gym_kit.dart';

final shoulderFigures = <String, FigurePlacement>{
  '89e28b79-35ed-4c74-8306-cccd0d06cb16': FigurePlacement(_overheadPress),
  '8eec37fa-e972-40f7-b83b-39bd934f4060': FigurePlacement(_shoulderPressMachine),
  'b56c9b50-a840-41b9-9bb7-772fe02f10fe': FigurePlacement(_seatedLateralRaise),
  'a9c64e10-41f1-4bb3-a698-0d34126f3b2f': FigurePlacement(_facePull),
  '869d70fc-9e7b-463a-a41e-d63d0da80e69': FigurePlacement(_barbellShrug),
};

const _standingLeg = LegAngles(thigh: 90, shin: 90, foot: 0);

final _overheadPress = FigureSpec(
  pose: Pose.fromAnkle(
    const Offset(89, onFloorY),
    torso: -89,
    head: -97,
    arms: const [ArmAngles(upper: -80, fore: -85)],
    legs: const [_standingLeg],
  ),
  equipment: [barbell(hand.shifted(0, -5))],
);

final _shoulderPressMachine = FigureSpec(
  pose: const Pose(
    hip: Offset(85, 152),
    torso: -90,
    head: -97,
    arms: [ArmAngles(upper: -70, fore: -75)],
    legs: [LegAngles(thigh: 5, shin: 95, foot: 0)],
  ),
  equipment: [
    EquipmentRoundRect(point(60, 157), point(112, 164)),
    pad(point(72, 156), point(72, 92)),
    EquipmentPolyline([point(62, 190), point(62, 36), hand.shifted(0, -3)]),
    post(85, 164),
    EquipmentLine(hand.shifted(-7, -3), hand.shifted(7, -3), width: 5, inFront: true),
  ],
);

const _lateralRaiseHip = Offset(100, 125);
const _lateralRaiseShoulderY = 78.0;
const _lateralRaiseArrowRadius = 62.0;

const _seatedLegs = [
  LegAngles(thigh: 96, shin: 90, foot: 170),
  LegAngles(thigh: 84, shin: 90, foot: 10),
];

List<Equipment> _lateralRaiseBench() => [
      EquipmentRoundRect(point(72, 133), point(128, 140)),
      post(84, 140),
      post(116, 140),
    ];

List<Equipment> _dumbbellsInBothHands() => [
      _smallDumbbell(hand),
      _smallDumbbell(const Anchor.at(Joint.wrist, limb: 1)),
    ];

Equipment _smallDumbbell(Anchor grip) => EquipmentRoundRect(
      grip.shifted(-4, -6),
      grip.shifted(4, 6),
      filled: true,
      inFront: true,
    );

final _seatedLateralRaise = FigureSpec(
  pose: const Pose(
    hip: _lateralRaiseHip,
    torso: -90,
    head: -90,
    arms: [ArmAngles(upper: 175, fore: 172), ArmAngles(upper: 5, fore: 8)],
    legs: _seatedLegs,
  ),
  equipment: [
    ..._lateralRaiseBench(),
    ..._dumbbellsInBothHands(),
    ...arcArrow(const Offset(88, _lateralRaiseShoulderY), _lateralRaiseArrowRadius, 118, 158),
    ...arcArrow(const Offset(112, _lateralRaiseShoulderY), _lateralRaiseArrowRadius, 62, 22),
  ],
  ghost: FigureSpec(
    pose: const Pose(
      hip: _lateralRaiseHip,
      torso: -90,
      head: -90,
      arms: [ArmAngles(upper: 100, fore: 97), ArmAngles(upper: 80, fore: 83)],
      legs: _seatedLegs,
    ),
    equipment: _dumbbellsInBothHands(),
  ),
);

final _facePull = FigureSpec(
  pose: Pose.fromAnkle(
    const Offset(85, onFloorY),
    torso: -90,
    head: -90,
    arms: const [ArmAngles(upper: 200, fore: -25)],
    legs: const [_standingLeg],
  ),
  equipment: [
    post(178, 50),
    ...cable(hand, 170, 59.7),
  ],
);

final _barbellShrug = FigureSpec(
  pose: Pose.fromAnkle(
    const Offset(90, onFloorY),
    torso: -90,
    head: -90,
    arms: const [ArmAngles(upper: 82, fore: 80)],
    legs: const [_standingLeg],
    neck: 4,
  ),
  equipment: [barbell(hand)],
);
