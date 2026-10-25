import 'dart:math';
import 'dart:ui';

const figureCanvasSize = Size(200, 200);
const figureFloorY = 190.0;

const torsoLength = 47.0;
const neckLength = 12.0;
const headRadius = 11.0;
const upperArmLength = 24.0;
const forearmLength = 24.0;
const thighLength = 30.0;
const shinLength = 30.0;
const footLength = 14.0;
const frontShoulderHalfWidth = 12.0;
const frontHipHalfWidth = 8.0;

/// Angles are degrees, absolute, in screen space: 0 points right, 90 points down.
class ArmAngles {
  const ArmAngles({required this.upper, required this.fore});

  final double upper;
  final double fore;
}

class LegAngles {
  const LegAngles({required this.thigh, required this.shin, required this.foot});

  final double thigh;
  final double shin;
  final double foot;
}

class Pose {
  const Pose({
    required this.hip,
    required this.torso,
    required this.head,
    required this.arms,
    required this.legs,
  });

  final Offset hip;
  final double torso;
  final double head;
  final List<ArmAngles> arms;
  final List<LegAngles> legs;
}

class ArmJoints {
  const ArmJoints({required this.elbow, required this.wrist});

  final Offset elbow;
  final Offset wrist;
}

class LegJoints {
  const LegJoints({required this.knee, required this.ankle, required this.toe});

  final Offset knee;
  final Offset ankle;
  final Offset toe;
}

class FigureJoints {
  const FigureJoints({
    required this.hip,
    required this.shoulder,
    required this.headCentre,
    required this.armRoots,
    required this.arms,
    required this.legRoots,
    required this.legs,
  });

  final Offset hip;
  final Offset shoulder;
  final Offset headCentre;
  final List<Offset> armRoots;
  final List<ArmJoints> arms;
  final List<Offset> legRoots;
  final List<LegJoints> legs;
}

FigureJoints poseJoints(Pose pose) {
  final shoulder = _step(pose.hip, pose.torso, torsoLength);
  final headCentre = _step(shoulder, pose.head, neckLength + headRadius);
  final armRoots = _limbRoots(shoulder, pose.arms.length, frontShoulderHalfWidth);
  final legRoots = _limbRoots(pose.hip, pose.legs.length, frontHipHalfWidth);
  return FigureJoints(
    hip: pose.hip,
    shoulder: shoulder,
    headCentre: headCentre,
    armRoots: armRoots,
    arms: [
      for (var i = 0; i < armRoots.length; i++) _arm(armRoots[i], pose.arms[i]),
    ],
    legRoots: legRoots,
    legs: [
      for (var i = 0; i < legRoots.length; i++) _leg(legRoots[i], pose.legs[i]),
    ],
  );
}

Offset mirrorPoint(Offset p) => Offset(figureCanvasSize.width - p.dx, p.dy);

FigureJoints mirrorJoints(FigureJoints j) {
  const m = mirrorPoint;
  return FigureJoints(
    hip: m(j.hip),
    shoulder: m(j.shoulder),
    headCentre: m(j.headCentre),
    armRoots: j.armRoots.map(m).toList(),
    arms: [for (final a in j.arms) ArmJoints(elbow: m(a.elbow), wrist: m(a.wrist))],
    legRoots: j.legRoots.map(m).toList(),
    legs: [
      for (final l in j.legs) LegJoints(knee: m(l.knee), ankle: m(l.ankle), toe: m(l.toe)),
    ],
  );
}

List<Offset> _limbRoots(Offset centre, int count, double frontHalfWidth) {
  if (count == 1) return [centre];
  return [
    centre.translate(-frontHalfWidth, 0),
    centre.translate(frontHalfWidth, 0),
  ];
}

ArmJoints _arm(Offset shoulder, ArmAngles a) {
  final elbow = _step(shoulder, a.upper, upperArmLength);
  return ArmJoints(elbow: elbow, wrist: _step(elbow, a.fore, forearmLength));
}

LegJoints _leg(Offset hip, LegAngles a) {
  final knee = _step(hip, a.thigh, thighLength);
  final ankle = _step(knee, a.shin, shinLength);
  return LegJoints(knee: knee, ankle: ankle, toe: _step(ankle, a.foot, footLength));
}

Offset _step(Offset from, double degrees, double length) {
  final radians = degrees * pi / 180;
  return from.translate(cos(radians) * length, sin(radians) * length);
}
