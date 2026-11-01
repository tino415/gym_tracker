import 'dart:ui';

import '../equipment.dart';
import '../figure_spec.dart';
import '../skeleton.dart';
import 'gym_kit.dart';

final backFigures = <String, FigurePlacement>{
  '9194a380-4f21-4093-8e75-d4c67ed8072e': FigurePlacement(_pullUp),
  'ea542f6f-e8a6-44a7-ae24-55af7bcd0d90': FigurePlacement(_chinUp),
  'dca635a8-e638-48f0-a84e-0445accc68b2': FigurePlacement(_pullUpNeutralGrip),
  'ce3931f4-4400-475d-a825-fb66af4825f0': FigurePlacement(_barbellRow),
  'f790e3d8-cbd3-4476-8da3-4c349850f81c': FigurePlacement(_dumbbellRow),
  'c31ce6c7-bf68-4a8a-be8f-145ad31b85bc': FigurePlacement(_chestSupportedDumbbellRow),
  'e105fd21-cd30-49ba-91a5-ba68ea18ea5f': FigurePlacement(_cableLatPullDown),
  'c561d9f3-4031-48b1-a7d8-141043ea925b': FigurePlacement(_narrowMagLatPullDown),
  '21cd13d1-5e37-4455-8b99-c8105878c8e3': FigurePlacement(_wideMagLatPullDown),
  '22dba14b-3529-4c27-926e-5eecebb9c2eb': FigurePlacement(_straightArmPullDown),
  '2afb40d4-a538-4584-9313-0efa382d1ec6': FigurePlacement(_seatedCableRow),
  '0f17c6bd-b446-443a-817e-b9630092679e': FigurePlacement(_seatedWideGripCableRow),
  'c9da715b-33ce-42f8-9e88-87b9431922d2': FigurePlacement(_seatedWideMagCableRow),
};

const _barY = 28.0;
const _rig = <Equipment>[
  EquipmentLine(Anchor.canvas(28, _barY), Anchor.canvas(172, _barY), width: 4),
  EquipmentLine(Anchor.canvas(32, _barY), Anchor.canvas(32, figureFloorY)),
  EquipmentLine(Anchor.canvas(168, _barY), Anchor.canvas(168, figureFloorY)),
];
const _wideGripHandX = 61.3;
const _neutralGripHandX = 69.0;
const _narrowGripHandX = 74.0;

ArmAngles _otherArm(ArmAngles arm) => ArmAngles(upper: 180 - arm.upper, fore: 180 - arm.fore);

Pose _hangingSeenFromBehind(double handX, ArmAngles leftArm) => Pose.fromWrist(
      Offset(handX, _barY),
      torso: -90,
      head: -90,
      arms: [leftArm, _otherArm(leftArm)],
      legs: const [
        LegAngles(thigh: 92, shin: 91, foot: 100),
        LegAngles(thigh: 88, shin: 89, foot: 80),
      ],
    );

final _pullUp = FigureSpec(
  pose: _hangingSeenFromBehind(_wideGripHandX, const ArmAngles(upper: 200, fore: -100)),
  equipment: _rig,
);

final _chinUp = FigureSpec(
  pose: _hangingSeenFromBehind(_narrowGripHandX, const ArmAngles(upper: 145, fore: -70)),
  equipment: _rig,
);

final _pullUpNeutralGrip = FigureSpec(
  pose: _hangingSeenFromBehind(_neutralGripHandX, const ArmAngles(upper: 165, fore: -80)),
  equipment: [
    ..._rig,
    EquipmentCircle(hand, 6, filled: true, inFront: true),
    const EquipmentCircle(Anchor.at(Joint.wrist, limb: 1), 6, filled: true, inFront: true),
  ],
);

final _barbellRow = FigureSpec(
  pose: Pose.fromAnkle(
    const Offset(100, onFloorY),
    torso: -30,
    head: -22,
    arms: const [ArmAngles(upper: 168, fore: 80)],
    legs: const [LegAngles(thigh: 65, shin: 100, foot: 0)],
  ),
  equipment: [barbell(hand)],
);

final _dumbbellRow = FigureSpec(
  pose: const Pose(
    hip: Offset(85, 128),
    torso: -10,
    head: -5,
    arms: [
      ArmAngles(upper: 112, fore: 62),
      ArmAngles(upper: 192, fore: 105),
    ],
    legs: [
      LegAngles(thigh: 86, shin: 175, foot: 150),
      LegAngles(thigh: 115, shin: 100, foot: 0),
    ],
    inProfile: true,
  ),
  equipment: [
    ...flatBench(44, 170, top: 163),
    ...dumbbell(const Anchor.at(Joint.wrist, limb: 1)),
  ],
);

final _chestSupportedDumbbellRow = FigureSpec(
  pose: Pose.fromAnkle(
    const Offset(45, 172),
    torso: -30,
    head: -25,
    arms: const [ArmAngles(upper: 185, fore: 100)],
    legs: const [LegAngles(thigh: 145, shin: 145, foot: 60)],
  ),
  equipment: [
    const EquipmentLine(Anchor.at(Joint.hip, dx: 2, dy: 9), Anchor.at(Joint.hip, dx: 32, dy: -8)),
    post(110, 139),
    ...dumbbell(hand),
  ],
);

const _pullDownArm = ArmAngles(upper: 95, fore: -60);

Pose _seatedAtPullDown() => const Pose(
      hip: Offset(85, 152),
      torso: -100,
      head: -95,
      arms: [_pullDownArm],
      legs: [LegAngles(thigh: 5, shin: 95, foot: 0)],
    );

List<Equipment> _pullDownMachine() => [
      post(172, 18),
      EquipmentLine(point(84, 18), point(172, 18)),
      EquipmentLine(point(120, 143), point(172, 143)),
      EquipmentRoundRect(point(104, 136), point(124, 146), filled: true),
      EquipmentRoundRect(point(60, 157), point(110, 164)),
      post(85, 164),
      ...cable(hand, 87, 18),
    ];

const _narrowMagHalfWidth = 8.0;
const _wideMagHalfWidth = 18.0;

final _cableLatPullDown = FigureSpec(
  pose: _seatedAtPullDown(),
  equipment: [..._pullDownMachine(), thinBar(hand), ...straightBarInset()],
);

final _narrowMagLatPullDown = FigureSpec(
  pose: _seatedAtPullDown(),
  equipment: [
    ..._pullDownMachine(),
    thinBar(hand),
    ...magHandleInset(halfWidth: _narrowMagHalfWidth),
  ],
);

final _wideMagLatPullDown = FigureSpec(
  pose: _seatedAtPullDown(),
  equipment: [
    ..._pullDownMachine(),
    thinBar(hand),
    ...magHandleInset(halfWidth: _wideMagHalfWidth),
  ],
);

final _straightArmPullDown = FigureSpec(
  pose: Pose.fromAnkle(
    const Offset(90, onFloorY),
    torso: -60,
    head: -55,
    arms: const [ArmAngles(upper: 78, fore: 78)],
    legs: const [LegAngles(thigh: 78, shin: 95, foot: 0)],
  ),
  equipment: [
    post(190, 15),
    ...cable(hand, 182, 15),
    thinBar(hand),
  ],
);

const _rowLegs = [LegAngles(thigh: -8, shin: 8, foot: -80)];

Pose _seatedAtRow(ArmAngles arm) => Pose(
      hip: const Offset(60, 160),
      torso: -90,
      head: -90,
      arms: [arm],
      legs: _rowLegs,
    );

List<Equipment> _rowMachine(double handleY) => [
      EquipmentRoundRect(point(40, 165), point(90, 172)),
      post(65, 172),
      EquipmentLine(point(130, 145), point(130, 175), width: 5),
      post(130, 175),
      post(160, handleY - 12),
      ...cable(hand, 154, handleY),
    ];

final _seatedCableRow = FigureSpec(
  pose: _seatedAtRow(const ArmAngles(upper: 115, fore: 0)),
  equipment: [..._rowMachine(134.8), thinBar(hand), ...vHandleInset()],
);

final _seatedWideGripCableRow = FigureSpec(
  pose: _seatedAtRow(const ArmAngles(upper: 145, fore: 10)),
  equipment: [..._rowMachine(130), thinBar(hand), ...straightBarInset()],
);

final _seatedWideMagCableRow = FigureSpec(
  pose: _seatedAtRow(const ArmAngles(upper: 130, fore: 0)),
  equipment: [
    ..._rowMachine(131.4),
    thinBar(hand),
    ...magHandleInset(halfWidth: _wideMagHalfWidth),
  ],
);
