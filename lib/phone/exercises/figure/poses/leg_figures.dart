import 'dart:ui';

import '../equipment.dart';
import '../figure_spec.dart';
import '../skeleton.dart';
import 'gym_kit.dart';

final legFigures = <String, FigurePlacement>{
  'c6beb1bd-0529-47c6-9494-7167a8ecce36': FigurePlacement(_backSquat),
  '2a0a37a9-d818-4071-b87d-f059a3a859d1': FigurePlacement(_frontSquat),
  '9c0c6889-56e4-4877-ade3-3ea74c4d6fc6': FigurePlacement(_legPress),
  '65ad1798-452a-46c2-ae02-66c57be1cfc8': FigurePlacement(_hackSquat),
  'e9b5f569-5bd8-4b35-9ca5-44778bd345bb': FigurePlacement(_legExtensionMachine),
  '8cbadf0b-f514-4802-90dc-e392588ec976': FigurePlacement(_lyingLegCurlMachine),
  'a049709b-5b29-4b56-a568-294d3d99f1d6': FigurePlacement(_deadlift),
  '840c9051-fb9f-4b22-8ea0-455799838cb4': FigurePlacement(_romanianDeadlift),
  '82a17c9b-ba19-4688-ad35-04087fa68bcd': FigurePlacement(_dumbbellRomanianDeadlift),
  '323cc733-a736-4461-b4e3-1da670681b6c': FigurePlacement(_hipThrust),
  '7f73526e-dff8-47c7-aa0e-d872c9e253e3': FigurePlacement(_walkingLunge),
  '2d8901cf-3d29-4f84-a34e-6af818155612': FigurePlacement(_bulgarianSplitSquat),
  'c5339658-fc16-4912-8754-434c2661ca21': FigurePlacement(_bulgarianSplitSquat),
  '272be082-6636-4482-aabd-71a09dcbadee': FigurePlacement(_bulgarianSplitSquat, mirrored: true),
  '579773aa-0b63-42f1-9abb-d35fc2fd151e': FigurePlacement(_calvesOnHackMachine),
  '9458211e-9c30-4ed2-bbe8-a36df320fbba': FigurePlacement(_calvesOnSmithMachine),
  '843ccf27-2ab9-4c34-aea9-5f202da7368b': FigurePlacement(_singleLegCalfRaise),
  'b8e2c538-de8b-4f52-ac6d-8e5d9167ad5e': FigurePlacement(_singleLegCalfRaise),
  'a0354315-d4c8-4f03-9844-4019a1b32c8c': FigurePlacement(_singleLegCalfRaise, mirrored: true),
};

const _backSquat = FigureSpec(
  pose: Pose(
    hip: Offset(81, 150),
    torso: -65,
    head: -75,
    arms: [ArmAngles(upper: 125, fore: -70)],
    legs: [LegAngles(thigh: 10, shin: 100, foot: -5)],
  ),
  equipment: [
    EquipmentCircle(Anchor.at(Joint.shoulder, dx: -4, dy: -4), 14, filled: true, inFront: true),
  ],
);

final _frontSquat = FigureSpec(
  pose: Pose.fromAnkle(
    const Offset(110, onFloorY),
    torso: -78,
    head: -82,
    arms: const [ArmAngles(upper: 0, fore: -165)],
    legs: const [LegAngles(thigh: -8, shin: 105, foot: 0)],
  ),
  equipment: [barbell(const Anchor.at(Joint.shoulder, dx: 10, dy: -6))],
);

final _legPress = FigureSpec(
  pose: const Pose(
    hip: Offset(92, 150),
    torso: 215,
    head: 215,
    arms: [ArmAngles(upper: 35, fore: 35)],
    legs: [LegAngles(thigh: -70, shin: -15, foot: -135)],
  ),
  equipment: [
    pad(point(30, 118), point(87, 157)),
    EquipmentLine(point(87, 157), point(108, 170), width: 7),
    post(60, 140),
    post(100, 170),
    EquipmentLine(point(95, 170), point(190, 75)),
    post(182, 83),
    pad(const Anchor.at(Joint.ankle, dx: 12, dy: 0), const Anchor.at(Joint.ankle, dx: -10, dy: -22)),
  ],
);

const _shoulderPad = EquipmentRoundRect(
  Anchor.at(Joint.shoulder, dx: -6, dy: -12),
  Anchor.at(Joint.shoulder, dx: 8, dy: -3),
  filled: true,
  inFront: true,
);

final _hackSquat = FigureSpec(
  pose: const Pose(
    hip: Offset(100, 150),
    torso: -135,
    head: -125,
    arms: [ArmAngles(upper: 30, fore: -60)],
    legs: [LegAngles(thigh: 0, shin: 92, foot: 0)],
  ),
  equipment: [
    pad(point(55, 123), point(100, 165)),
    _shoulderPad,
    EquipmentLine(point(40, 110), point(112, 178)),
    EquipmentRoundRect(point(118, 186), point(160, 190), filled: true),
    post(45, 115),
  ],
);

final _legExtensionMachine = FigureSpec(
  pose: const Pose(
    hip: Offset(60, onBenchY),
    torso: -90,
    head: -90,
    arms: [ArmAngles(upper: 100, fore: 85)],
    legs: [LegAngles(thigh: 0, shin: -2, foot: -60)],
  ),
  equipment: [
    EquipmentRoundRect(point(40, benchTopY), point(95, benchTopY + 7)),
    pad(point(47, benchTopY), point(47, 100)),
    post(60, benchTopY + 7),
    EquipmentLine(point(90, 153), const Anchor.at(Joint.ankle, dx: -3, dy: -10)),
    EquipmentCircle(const Anchor.at(Joint.ankle, dx: -3, dy: -11), 7, filled: true, inFront: true),
  ],
);

final _lyingLegCurlMachine = FigureSpec(
  pose: const Pose(
    hip: Offset(85, 125),
    torso: 0,
    head: -20,
    arms: [ArmAngles(upper: 75, fore: 25)],
    legs: [LegAngles(thigh: 180, shin: -90, foot: 180)],
  ),
  equipment: [
    EquipmentRoundRect(point(40, 130), point(170, 137)),
    post(60, 137),
    post(150, 137),
    EquipmentLine(point(58, 125), const Anchor.at(Joint.ankle, dx: 8, dy: 6)),
    EquipmentCircle(const Anchor.at(Joint.ankle, dx: 9, dy: 7), 7, filled: true, inFront: true),
  ],
);

final _deadlift = FigureSpec(
  pose: Pose.fromAnkle(
    const Offset(90, onFloorY),
    torso: -25,
    head: -18,
    arms: const [ArmAngles(upper: 94, fore: 94)],
    legs: const [LegAngles(thigh: 20, shin: 105, foot: 0)],
  ),
  equipment: [barbell(point(108, figureFloorY - 14))],
);

const _romanianDeadliftLeg = LegAngles(thigh: 78, shin: 92, foot: 0);

Pose _romanianDeadliftPose() => Pose.fromAnkle(
      const Offset(100, onFloorY),
      torso: -12,
      head: -5,
      arms: const [ArmAngles(upper: 105, fore: 105)],
      legs: const [_romanianDeadliftLeg],
    );

final _romanianDeadlift = FigureSpec(
  pose: _romanianDeadliftPose(),
  equipment: [barbell(hand)],
);

final _dumbbellRomanianDeadlift = FigureSpec(
  pose: _romanianDeadliftPose(),
  equipment: [endOnDumbbell(hand)],
);

final _hipThrust = FigureSpec(
  pose: const Pose(
    hip: Offset(105, 152),
    torso: 184,
    head: 184,
    arms: [ArmAngles(upper: -22, fore: -22)],
    legs: [LegAngles(thigh: 6, shin: 90, foot: 0)],
  ),
  equipment: [
    ...flatBench(28, 68),
    barbell(const Anchor.at(Joint.hip, dy: -16)),
  ],
);

const _lungeFrontLeg = LegAngles(thigh: 0, shin: 90, foot: 0);

final _walkingLunge = FigureSpec(
  pose: Pose.fromAnkle(
    const Offset(128, onFloorY),
    torso: -90,
    head: -90,
    arms: const [ArmAngles(upper: 90, fore: 88)],
    legs: const [
      _lungeFrontLeg,
      LegAngles(thigh: 130, shin: 190, foot: 60),
    ],
    inProfile: true,
  ),
  equipment: dumbbell(hand),
);

final _bulgarianSplitSquat = FigureSpec(
  pose: Pose.fromAnkle(
    const Offset(128, onFloorY),
    torso: -90,
    head: -90,
    arms: const [ArmAngles(upper: 90, fore: 88)],
    legs: const [
      _lungeFrontLeg,
      LegAngles(thigh: 140, shin: 230, foot: 175),
    ],
    inProfile: true,
  ),
  equipment: [...flatBench(18, 60), ...dumbbell(hand)],
);

const _toeOnStep = Offset(110, 170);
const _raisedFoot = LegAngles(thigh: 90, shin: 90, foot: 60);

Offset _ankleAboveToe(Offset toe) => toe.translate(-7, -12.1);

List<Equipment> _step(double left, double right) => [
      EquipmentRoundRect(point(left, 175), point(right, figureFloorY)),
    ];

final _calvesOnHackMachine = FigureSpec(
  pose: Pose.fromAnkle(
    _ankleAboveToe(const Offset(110, 165)),
    torso: -70,
    head: -65,
    arms: const [ArmAngles(upper: 30, fore: -80)],
    legs: const [LegAngles(thigh: 110, shin: 110, foot: 60)],
  ),
  equipment: [
    EquipmentRoundRect(point(102, 170), point(170, 177)),
    post(160, 177),
    pad(const Anchor.at(Joint.hip, dx: 14, dy: 4), const Anchor.at(Joint.shoulder, dx: 14, dy: 4)),
    EquipmentLine(const Anchor.at(Joint.shoulder, dx: 18, dy: 6), point(175, 177)),
    _shoulderPad,
  ],
);

final _calvesOnSmithMachine = FigureSpec(
  pose: Pose.fromAnkle(
    _ankleAboveToe(_toeOnStep),
    torso: -90,
    head: -90,
    arms: const [ArmAngles(upper: 125, fore: -70)],
    legs: const [_raisedFoot],
  ),
  equipment: [
    ..._step(92, 130),
    EquipmentLine(point(95, 6), point(95, figureFloorY)),
    barbell(const Anchor.at(Joint.shoulder, dx: -6, dy: -4)),
  ],
);

final _singleLegCalfRaise = FigureSpec(
  pose: Pose.fromAnkle(
    _ankleAboveToe(_toeOnStep),
    torso: -90,
    head: -90,
    arms: const [ArmAngles(upper: 25, fore: 5)],
    legs: const [
      _raisedFoot,
      LegAngles(thigh: 95, shin: 160, foot: 70),
    ],
    inProfile: true,
  ),
  equipment: [
    ..._step(92, 130),
    EquipmentLine(point(154, 30), point(154, figureFloorY)),
  ],
);
