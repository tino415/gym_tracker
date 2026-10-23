import 'dart:ui';

import '../../data/muscle_seeds.dart' as seeds;

enum BodyView { front, back }

const bodyViewSize = Size(100, 220);

class RegionShape {
  const RegionShape(this.bounds, {this.roundness = 1, this.mirrored = true});

  final Rect bounds;
  final double roundness;
  final bool mirrored;

  Iterable<RRect> rects() sync* {
    yield _rounded(bounds);
    if (mirrored) {
      yield _rounded(Rect.fromLTRB(
        bodyViewSize.width - bounds.right,
        bounds.top,
        bodyViewSize.width - bounds.left,
        bounds.bottom,
      ));
    }
  }

  RRect _rounded(Rect r) =>
      RRect.fromRectAndRadius(r, Radius.circular(roundness * r.shortestSide / 2));
}

const silhouette = <RegionShape>[
  RegionShape(Rect.fromLTRB(38, 4, 62, 28), mirrored: false),
  RegionShape(Rect.fromLTRB(44, 24, 56, 38), roundness: 0.3, mirrored: false),
  RegionShape(Rect.fromLTRB(28, 32, 72, 114), roundness: 0.4, mirrored: false),
  RegionShape(Rect.fromLTRB(16, 36, 30, 86), roundness: 0.8),
  RegionShape(Rect.fromLTRB(12, 82, 26, 126), roundness: 0.8),
  RegionShape(Rect.fromLTRB(11, 122, 24, 138)),
  RegionShape(Rect.fromLTRB(30, 104, 70, 126), roundness: 0.5, mirrored: false),
  RegionShape(Rect.fromLTRB(30, 116, 49.5, 172), roundness: 0.8),
  RegionShape(Rect.fromLTRB(32, 168, 47, 208), roundness: 0.8),
  RegionShape(Rect.fromLTRB(31, 204, 47, 214), roundness: 0.6),
];

enum BodyRegion {
  frontDelts(BodyView.front, 'Shoulders', RegionShape(Rect.fromLTRB(18, 34, 34, 50))),
  chest(BodyView.front, 'Chest', RegionShape(Rect.fromLTRB(32, 42, 49, 64), roundness: 0.6)),
  biceps(BodyView.front, 'Biceps', RegionShape(Rect.fromLTRB(18, 52, 28, 80))),
  frontForearms(BodyView.front, 'Forearms', RegionShape(Rect.fromLTRB(14, 88, 24, 118))),
  abs(BodyView.front, 'Abs',
      RegionShape(Rect.fromLTRB(40, 66, 60, 104), roundness: 0.4, mirrored: false)),
  quads(BodyView.front, 'Quads', RegionShape(Rect.fromLTRB(32, 126, 48, 166))),
  traps(BodyView.back, 'Back', RegionShape(Rect.fromLTRB(38, 30, 62, 54), roundness: 0.7, mirrored: false)),
  rearDelts(BodyView.back, 'Shoulders', RegionShape(Rect.fromLTRB(18, 34, 34, 50))),
  lats(BodyView.back, 'Back', RegionShape(Rect.fromLTRB(31, 54, 48, 88), roundness: 0.6)),
  lowerBack(BodyView.back, 'Back',
      RegionShape(Rect.fromLTRB(42, 86, 58, 106), roundness: 0.5, mirrored: false)),
  triceps(BodyView.back, 'Triceps', RegionShape(Rect.fromLTRB(18, 50, 28, 80))),
  backForearms(BodyView.back, 'Forearms', RegionShape(Rect.fromLTRB(14, 88, 24, 118))),
  glutes(BodyView.back, 'Glutes', RegionShape(Rect.fromLTRB(31, 106, 50, 130))),
  hamstrings(BodyView.back, 'Hamstrings', RegionShape(Rect.fromLTRB(32, 132, 48, 168))),
  calves(BodyView.back, 'Calves', RegionShape(Rect.fromLTRB(33, 172, 47, 200)));

  const BodyRegion(this.view, this.muscleName, this.shape);

  final BodyView view;
  final String muscleName;
  final RegionShape shape;

  String get muscleSyncId => seeds.muscleSyncId(muscleName);
}

Set<BodyRegion> regionsOf(Set<String> muscleSyncIds) => {
      for (final region in BodyRegion.values)
        if (muscleSyncIds.contains(region.muscleSyncId)) region,
    };
