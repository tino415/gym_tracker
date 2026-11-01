import 'dart:ui';

import 'skeleton.dart';

enum Joint { hip, shoulder, head, elbow, wrist, knee, ankle, toe }

/// A point either fixed on the canvas or carried by a joint of the figure.
class Anchor {
  const Anchor.canvas(this.dx, this.dy)
      : joint = null,
        limb = 0;

  const Anchor.at(Joint this.joint, {this.limb = 0, this.dx = 0, this.dy = 0});

  final Joint? joint;
  final int limb;
  final double dx;
  final double dy;

  Anchor shifted(double byX, double byY) {
    final joint = this.joint;
    return joint == null
        ? Anchor.canvas(dx + byX, dy + byY)
        : Anchor.at(joint, limb: limb, dx: dx + byX, dy: dy + byY);
  }

  Offset resolve(FigureJoints joints) {
    final joint = this.joint;
    final origin = joint == null ? Offset.zero : _jointPosition(joints, joint, limb);
    return origin.translate(dx, dy);
  }
}

Offset _jointPosition(FigureJoints j, Joint joint, int limb) => switch (joint) {
      Joint.hip => j.hip,
      Joint.shoulder => j.shoulder,
      Joint.head => j.headCentre,
      Joint.elbow => j.arms[limb].elbow,
      Joint.wrist => j.arms[limb].wrist,
      Joint.knee => j.legs[limb].knee,
      Joint.ankle => j.legs[limb].ankle,
      Joint.toe => j.legs[limb].toe,
    };

sealed class Equipment {
  const Equipment({this.width = 3, this.inFront = false});

  final double width;
  final bool inFront;
}

class EquipmentLine extends Equipment {
  const EquipmentLine(this.from, this.to, {super.width, super.inFront});

  final Anchor from;
  final Anchor to;
}

class EquipmentPolyline extends Equipment {
  const EquipmentPolyline(this.points, {super.width, super.inFront});

  final List<Anchor> points;
}

class EquipmentCircle extends Equipment {
  const EquipmentCircle(this.centre, this.radius, {this.filled = false, super.width, super.inFront});

  final Anchor centre;
  final double radius;
  final bool filled;
}

class EquipmentRoundRect extends Equipment {
  const EquipmentRoundRect(this.corner, this.oppositeCorner,
      {this.radius = 3, this.filled = false, super.width, super.inFront});

  final Anchor corner;
  final Anchor oppositeCorner;
  final double radius;
  final bool filled;
}
