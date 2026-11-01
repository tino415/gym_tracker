import 'dart:ui';

import '../equipment.dart';
import '../figure_spec.dart';
import '../skeleton.dart';
import 'gym_kit.dart';

final trxFigures = <String, FigurePlacement>{
  '8e5380ec-43a9-4f47-8fd5-e7cf6e6e085f': FigurePlacement(_trxBicepsCurl),
  'aa8ee3f8-c7e4-4d33-b140-a0137acd103f': FigurePlacement(_trxTricepsExtension),
  '7c1c7009-a725-4f5d-a80c-3359958f7d3f': FigurePlacement(_trxFacePull),
  '8d67c0a9-6bcd-4377-99c7-8b20ada143cb': FigurePlacement(_trxFallout),
  'ef857baf-464f-4934-9ebe-c56b92310267': FigurePlacement(_trxHighRow),
  '8b5aa84c-1d92-406c-9408-3652376d239e': FigurePlacement(_trxLowRow),
  'dc72c53a-7bf9-4d2a-af15-5848c4ad4c27': FigurePlacement(_trxPike),
  'ac1e0107-69d6-4df3-9708-300f48f7ac01': FigurePlacement(_trxSuspendedPushUp),
  'f460e2b4-a8e4-49f6-a907-f6a4b9f774a5': FigurePlacement(_trxBulgarianSplitSquat),
  '2de0032e-359a-403a-bb71-dd7a055767fc': FigurePlacement(_trxBulgarianSplitSquat),
  '740c47ff-3c89-4bf6-af87-15d5356c943f': FigurePlacement(_trxBulgarianSplitSquat, mirrored: true),
  '03e47606-0b15-4bfd-837a-130af6f174c8': FigurePlacement(_trxPistolSquat),
  'd0be3db9-cd9a-4f16-8b7b-b2b924452762': FigurePlacement(_trxPistolSquat),
  '78e73ca3-883f-480e-96ad-8a1c2422a470': FigurePlacement(_trxPistolSquat, mirrored: true),
  '4bfb5724-45d7-47d6-a9d3-c68049d7ae69': FigurePlacement(_trxSingleLegRomanianDeadlift),
  '916bafa9-47dc-43bd-9216-5dd3ce477f44': FigurePlacement(_trxSingleLegRomanianDeadlift),
  '756d1ce7-a160-47eb-b13c-a19007332f17': FigurePlacement(_trxSingleLegRomanianDeadlift, mirrored: true),
};

const _anchorInFrontX = 175.0;
const _anchorBehindX = 25.0;
const _hangY = 22.0;

List<Equipment> _strapToHand(double anchorX) => [
      ...trxAnchor(anchorX),
      strap(point(anchorX, _hangY), hand),
      strapHandle(hand),
    ];

List<Equipment> _strapToFoot(double anchorX) => [
      ...trxAnchor(anchorX),
      strap(point(anchorX, _hangY), const Anchor.at(Joint.ankle)),
    ];

Pose _leaningBack(ArmAngles arm) => Pose(
      hip: const Offset(90, 133),
      torso: -120,
      head: -119,
      arms: [arm],
      legs: const [LegAngles(thigh: 60, shin: 60, foot: -36)],
    );

Pose _leaningForward(ArmAngles arm, {double degrees = 60, required double ankleX, double? head}) => Pose.fromAnkle(
      Offset(ankleX, 172),
      torso: -degrees,
      head: head ?? -degrees + 1,
      arms: [arm],
      legs: [LegAngles(thigh: 180 - degrees, shin: 180 - degrees, foot: 65)],
    );

final _trxBicepsCurl = FigureSpec(
  pose: _leaningBack(const ArmAngles(upper: -33, fore: 200)),
  equipment: _strapToHand(_anchorInFrontX),
);

final _trxTricepsExtension = FigureSpec(
  pose: _leaningForward(const ArmAngles(upper: -50, fore: -150), ankleX: 80, head: -25),
  equipment: _strapToHand(_anchorBehindX),
);

final _trxFacePull = FigureSpec(
  pose: _leaningBack(const ArmAngles(upper: 200, fore: -35)),
  equipment: _strapToHand(_anchorInFrontX),
);

final _trxFallout = FigureSpec(
  pose: _leaningForward(const ArmAngles(upper: -50, fore: -45), degrees: 30, ankleX: 28),
  equipment: _strapToHand(_anchorBehindX),
);

final _trxHighRow = FigureSpec(
  pose: _leaningBack(const ArmAngles(upper: 190, fore: 5)),
  equipment: _strapToHand(_anchorInFrontX),
);

final _trxLowRow = FigureSpec(
  pose: _leaningBack(const ArmAngles(upper: 95, fore: -38)),
  equipment: _strapToHand(_anchorInFrontX),
);

final _trxPike = FigureSpec(
  pose: Pose.fromWrist(
    const Offset(140, onFloorY),
    torso: 42,
    head: 40,
    arms: const [ArmAngles(upper: 90, fore: 90)],
    legs: const [LegAngles(thigh: 130, shin: 130, foot: 40)],
  ),
  equipment: _strapToFoot(66),
);

final _trxSuspendedPushUp = FigureSpec(
  pose: Pose.fromWrist(
    const Offset(150, onFloorY),
    torso: 7,
    head: 7,
    arms: const [ArmAngles(upper: 142, fore: 18)],
    legs: const [LegAngles(thigh: 187, shin: 187, foot: 97)],
  ),
  equipment: _strapToFoot(40),
);

final _trxBulgarianSplitSquat = FigureSpec(
  pose: Pose.fromAnkle(
    const Offset(128, onFloorY),
    torso: -90,
    head: -90,
    arms: const [ArmAngles(upper: 120, fore: 60)],
    legs: const [
      LegAngles(thigh: 0, shin: 90, foot: 0),
      LegAngles(thigh: 140, shin: 230, foot: 175),
    ],
    inProfile: true,
  ),
  equipment: [
    ...trxAnchor(_anchorBehindX),
    strap(point(_anchorBehindX, _hangY), const Anchor.at(Joint.ankle, limb: 1)),
  ],
);

final _trxPistolSquat = FigureSpec(
  pose: Pose.fromAnkle(
    const Offset(90, onFloorY),
    torso: -70,
    head: -75,
    arms: const [ArmAngles(upper: -46, fore: -46)],
    legs: const [
      LegAngles(thigh: -8, shin: 105, foot: 0),
      LegAngles(thigh: 18, shin: 18, foot: -70),
    ],
    inProfile: true,
  ),
  equipment: _strapToHand(_anchorInFrontX),
);

final _trxSingleLegRomanianDeadlift = FigureSpec(
  pose: Pose.fromAnkle(
    const Offset(70, onFloorY),
    torso: -25,
    head: -30,
    arms: const [ArmAngles(upper: 18, fore: 18)],
    legs: const [
      LegAngles(thigh: 80, shin: 95, foot: 0),
      LegAngles(thigh: 155, shin: 155, foot: 65),
    ],
    inProfile: true,
  ),
  equipment: _strapToHand(_anchorInFrontX),
);
