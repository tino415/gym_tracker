import 'dart:ui';

import 'equipment.dart';
import 'skeleton.dart';

class FigureSpec {
  const FigureSpec({
    required this.pose,
    this.equipment = const [],
    this.ghost,
    this.hasFloor = true,
  });

  final Pose pose;
  final List<Equipment> equipment;

  /// Another moment of the movement, painted faded behind this one.
  final FigureSpec? ghost;

  /// A view from above has no floor line.
  final bool hasFloor;
}

/// A figure placed for one exercise; [mirrored] turns a base pose into its
/// opposite-side variant.
class FigurePlacement {
  const FigurePlacement(this.spec, {this.mirrored = false});

  final FigureSpec spec;
  final bool mirrored;

  FigurePlacement? get ghost {
    final ghost = spec.ghost;
    return ghost == null ? null : FigurePlacement(ghost, mirrored: mirrored);
  }

  FigureJoints get joints {
    final joints = poseJoints(spec.pose);
    return mirrored ? mirrorJoints(joints) : joints;
  }

  Offset resolve(Anchor anchor) {
    final point = anchor.resolve(poseJoints(spec.pose));
    return mirrored ? mirrorPoint(point) : point;
  }
}
