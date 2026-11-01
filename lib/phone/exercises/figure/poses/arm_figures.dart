import 'dart:ui';

import '../equipment.dart';
import '../figure_spec.dart';
import '../skeleton.dart';
import 'gym_kit.dart';

final armFigures = <String, FigurePlacement>{
  'eda04b53-dce7-4349-9f19-cd193a2166a6': FigurePlacement(_cableBicepsCurl),
  '46c6d0a1-abc5-4cf6-b82a-efec6e65e311': FigurePlacement(_dumbbellHammerCurl),
  '1277b39d-b73a-4fca-bac9-efcf2adb0388': FigurePlacement(_barbellCurl),
  'f0ae1f30-2cf7-424c-a35f-46f06abee833': FigurePlacement(_dumbbellSkullCrusher),
  '22efb320-83ff-4636-8695-96e09fafb304': FigurePlacement(_overheadCableTricepsExtension),
  '7884b8b7-690d-4f8e-9be5-d35578d0745b': FigurePlacement(_seatedOverheadDumbbellExtension),
  'e0bf42c4-8a5d-4c8a-a5fa-5e50ba4e3f7c': FigurePlacement(_tricepsPushDown),
  '4cab971b-7df1-43f8-bf4b-6c6787b922b1': FigurePlacement(_benchDips),
};

const _standingLeg = LegAngles(thigh: 90, shin: 90, foot: 0);
const _curlArm = ArmAngles(upper: 82, fore: -45);

Pose _standingCurl() => Pose.fromAnkle(
      const Offset(80, onFloorY),
      torso: -90,
      head: -90,
      arms: const [_curlArm],
      legs: const [_standingLeg],
    );

final _cableBicepsCurl = FigureSpec(
  pose: _standingCurl(),
  equipment: [
    EquipmentLine(point(168, 190), point(168, 165)),
    ...cable(hand, 160, 172),
    thinBar(hand),
  ],
);

final _dumbbellHammerCurl = FigureSpec(
  pose: _standingCurl(),
  equipment: uprightDumbbell(hand),
);

final _barbellCurl = FigureSpec(
  pose: _standingCurl(),
  equipment: [barbell(hand)],
);

final _dumbbellSkullCrusher = FigureSpec(
  pose: const Pose(
    hip: Offset(124, onBenchY),
    torso: 180,
    head: 180,
    arms: [ArmAngles(upper: -90, fore: 150)],
    legs: [LegAngles(thigh: 5, shin: 100, foot: 0)],
  ),
  equipment: [...flatBench(40, 130), ...dumbbell(hand)],
);

final _overheadCableTricepsExtension = FigureSpec(
  pose: Pose.fromAnkle(
    const Offset(135, onFloorY),
    torso: -78,
    head: -75,
    arms: const [ArmAngles(upper: -50, fore: 165)],
    legs: const [
      LegAngles(thigh: 75, shin: 95, foot: 0),
      LegAngles(thigh: 115, shin: 130, foot: 20),
    ],
    inProfile: true,
  ),
  equipment: [
    post(22, 55),
    ...cable(hand, 30, 55),
  ],
);

final _seatedOverheadDumbbellExtension = FigureSpec(
  pose: const Pose(
    hip: Offset(90, onBenchY),
    torso: -90,
    head: -75,
    arms: [ArmAngles(upper: -95, fore: 140)],
    legs: [LegAngles(thigh: 5, shin: 95, foot: 0)],
  ),
  equipment: [
    ...flatBench(60, 118),
    ...dumbbell(hand),
  ],
);

final _tricepsPushDown = FigureSpec(
  pose: Pose.fromAnkle(
    const Offset(85, onFloorY),
    torso: -90,
    head: -90,
    arms: const [ArmAngles(upper: 85, fore: 75)],
    legs: const [_standingLeg],
  ),
  equipment: [
    post(136, 15),
    ...cable(hand, 128, 15),
    thinBar(hand),
  ],
);

final _benchDips = FigureSpec(
  pose: const Pose(
    hip: Offset(75, 165),
    torso: -90,
    head: -90,
    arms: [ArmAngles(upper: 152, fore: 80)],
    legs: [LegAngles(thigh: 20, shin: 18, foot: -75)],
  ),
  equipment: flatBench(20, 60),
);
