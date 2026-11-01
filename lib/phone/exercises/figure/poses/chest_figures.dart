import 'dart:ui';

import '../equipment.dart';
import '../figure_spec.dart';
import '../skeleton.dart';
import 'gym_kit.dart';

final chestFigures = <String, FigurePlacement>{
  'bd70c034-c732-4672-b103-b4b642f9560b': FigurePlacement(_benchPress),
  '2a664154-c337-4ec9-a44b-ab0570752e66': FigurePlacement(_inclineBenchPress),
  'aea8d5c9-a64e-4143-b3c1-23fbce2e4c0a': FigurePlacement(_dumbbellBenchPress),
  '2c9c6e58-cfea-4437-a1fe-60a9c07f1bcb': FigurePlacement(_dumbbellChestFly),
  '2a2bb0f0-e2e2-4ddf-a1e6-437fe0a9ea3f': FigurePlacement(_mildInclineDumbbellPress),
  '838d0ea9-e8f1-446c-90b9-cafe7abf948b': FigurePlacement(_pushUp),
  '9bc038a7-4f19-46ef-9715-bea24e1dd7b6': FigurePlacement(_declineWidePushUp),
  '4f0303e6-8bf6-4d9b-9801-734d8c61a49b': FigurePlacement(_parallelBarsDips),
  'a7381128-895b-478e-80f6-976b8ca69177': FigurePlacement(_cableChestFly),
  '68ad3fe1-7136-4fe9-8f63-7ddc8dc8c261': FigurePlacement(_dumbbellPullover),
};

const _benchLeg = LegAngles(thigh: 5, shin: 100, foot: 0);
const _pushUpArm = ArmAngles(upper: 142, fore: 18);

Pose _lyingOnBench(ArmAngles arm) => Pose(
      hip: const Offset(112, onBenchY),
      torso: 180,
      head: 180,
      arms: [arm],
      legs: const [_benchLeg],
    );

final _benchPress = FigureSpec(
  pose: _lyingOnBench(const ArmAngles(upper: 40, fore: -90)),
  equipment: [...flatBench(28, 118), barbell(hand)],
);

final _inclineBenchPress = FigureSpec(
  pose: const Pose(
    hip: Offset(112, 150),
    torso: 210,
    head: 210,
    arms: [ArmAngles(upper: 60, fore: -90)],
    legs: [LegAngles(thigh: 10, shin: 96, foot: 0)],
  ),
  equipment: [..._inclineBench(), barbell(hand)],
);

List<Equipment> _inclineBench() => [
      pad(point(46, 124), point(106, 159)),
      EquipmentLine(point(100, 159), point(126, 159), width: 7),
      EquipmentLine(point(112, 159), point(112, figureFloorY)),
      post(70, 139),
    ];

final _dumbbellBenchPress = FigureSpec(
  pose: _lyingOnBench(const ArmAngles(upper: 50, fore: -90)),
  equipment: [...flatBench(28, 118), ...dumbbell(hand)],
);

final _dumbbellChestFly = FigureSpec(
  pose: _lyingOnBench(const ArmAngles(upper: 50, fore: -30)),
  equipment: [...flatBench(28, 118), ...dumbbell(hand)],
);

final _mildInclineDumbbellPress = FigureSpec(
  pose: const Pose(
    hip: Offset(112, 152),
    torso: 195,
    head: 195,
    arms: [ArmAngles(upper: 55, fore: -90)],
    legs: [LegAngles(thigh: 8, shin: 98, foot: 0)],
  ),
  equipment: [
    pad(point(40, 142), point(108, 160)),
    EquipmentLine(point(100, 160), point(124, 160), width: 7),
    post(112, 160),
    post(60, 150),
    ...dumbbell(hand),
  ],
);

final _pushUp = FigureSpec(
  pose: Pose.fromWrist(
    const Offset(150, onFloorY),
    torso: -5,
    head: -5,
    arms: const [_pushUpArm],
    legs: const [LegAngles(thigh: 175, shin: 175, foot: 70)],
  ),
);

final _declineWidePushUp = FigureSpec(
  pose: Pose.fromWrist(
    const Offset(152, onFloorY),
    torso: 12,
    head: 12,
    arms: const [_pushUpArm],
    legs: const [LegAngles(thigh: 192, shin: 192, foot: 75)],
  ),
  equipment: flatBench(20, 66),
);

final _parallelBarsDips = FigureSpec(
  pose: Pose.fromWrist(
    const Offset(100, 112),
    torso: -80,
    head: -80,
    arms: const [ArmAngles(upper: 135, fore: 45)],
    legs: const [LegAngles(thigh: 95, shin: 165, foot: 120)],
  ),
  equipment: [
    EquipmentLine(point(58, 116), point(150, 116), width: 4),
    post(70, 116),
    post(140, 116),
  ],
);

final _cableChestFly = FigureSpec(
  pose: Pose.fromAnkle(
    const Offset(125, onFloorY),
    torso: -78,
    head: -78,
    arms: const [ArmAngles(upper: 60, fore: 40)],
    legs: const [
      LegAngles(thigh: 75, shin: 95, foot: 0),
      LegAngles(thigh: 115, shin: 130, foot: 20),
    ],
    inProfile: true,
  ),
  equipment: [
    post(22, 22),
    ...cable(hand, 30, 22),
    thinBar(hand),
  ],
);

final _dumbbellPullover = FigureSpec(
  pose: const Pose(
    hip: Offset(124, onBenchY),
    torso: 180,
    head: 180,
    arms: [ArmAngles(upper: 150, fore: 165)],
    legs: [_benchLeg],
  ),
  equipment: [...flatBench(58, 100), ...dumbbell(hand)],
);
