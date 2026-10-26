import 'dart:ui';

import 'equipment.dart';
import 'skeleton.dart';

class FigureSpec {
  const FigureSpec({required this.pose, this.equipment = const []});

  final Pose pose;
  final List<Equipment> equipment;
}

/// A figure placed for one exercise; [mirrored] turns a base pose into its
/// opposite-side variant.
class FigurePlacement {
  const FigurePlacement(this.spec, {this.mirrored = false});

  final FigureSpec spec;
  final bool mirrored;

  FigureJoints get joints {
    final joints = poseJoints(spec.pose);
    return mirrored ? mirrorJoints(joints) : joints;
  }

  Offset resolve(Anchor anchor) {
    final point = anchor.resolve(poseJoints(spec.pose));
    return mirrored ? mirrorPoint(point) : point;
  }
}
