import 'figure_spec.dart';
import 'poses/arm_figures.dart';
import 'poses/back_figures.dart';
import 'poses/chest_figures.dart';
import 'poses/conditioning_figures.dart';
import 'poses/core_figures.dart';
import 'poses/leg_figures.dart';
import 'poses/shoulder_figures.dart';
import 'poses/trx_figures.dart';

FigurePlacement? figureFor(String? exerciseId) => figurePlacements[exerciseId];

final figureGroups = <String, Map<String, FigurePlacement>>{
  'chest': chestFigures,
  'back': backFigures,
  'shoulders': shoulderFigures,
  'arms': armFigures,
  'legs': legFigures,
  'core': coreFigures,
  'trx': trxFigures,
  'conditioning': conditioningFigures,
};

final figurePlacements = <String, FigurePlacement>{
  for (final group in figureGroups.values) ...group,
};
