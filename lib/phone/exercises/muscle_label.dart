import '../../l10n/l10n.dart';

String muscleLabel(AppLocalizations l10n, String storedName) =>
    switch (storedName) {
      'Chest' => l10n.commonMuscleChest,
      'Back' => l10n.commonMuscleBack,
      'Shoulders' => l10n.commonMuscleShoulders,
      'Biceps' => l10n.commonMuscleBiceps,
      'Triceps' => l10n.commonMuscleTriceps,
      'Forearms' => l10n.commonMuscleForearms,
      'Abs' => l10n.commonMuscleAbs,
      'Quads' => l10n.commonMuscleQuads,
      'Hamstrings' => l10n.commonMuscleHamstrings,
      'Glutes' => l10n.commonMuscleGlutes,
      'Calves' => l10n.commonMuscleCalves,
      _ => storedName,
    };
