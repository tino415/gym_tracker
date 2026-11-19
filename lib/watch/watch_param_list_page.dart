import 'package:flutter/material.dart';

import '../data/exercise_params.dart';
import '../l10n/l10n.dart';
import 'set_target_format.dart';
import 'widgets/set_value_editor_page.dart';

const weightStep = 2.5;

Future<void> editWeight(
  BuildContext context, {
  required double weightKg,
  required ValueChanged<double> onChanged,
}) async {
  final locale = Localizations.localeOf(context).toString();
  final edited = await editSetValue<double>(
    context,
    value: weightKg,
    step: weightStep,
    min: 0,
    formatter: (w) => formatWeight(w, locale: locale),
    unit: context.l10n.watchUnitKg,
  );
  if (edited != null) onChanged(edited);
}

Future<void> editParam(
  BuildContext context, {
  required CustomParam param,
  required double? value,
  required ValueChanged<double> onChanged,
}) async {
  final edited = await editSetValue<double>(
    context,
    value: value ?? 0,
    step: paramStep(value),
    min: 0,
    formatter: formatParamValue,
    unit: param.name,
  );
  if (edited != null) onChanged(edited);
}

/// The page right of the set face: every entry of the exercise's parameter
/// list except the one on the face, each opening the value editor.
class WatchParamListPage extends StatelessWidget {
  const WatchParamListPage({
    super.key,
    required this.entries,
    required this.weightKg,
    required this.values,
    required this.onWeightChanged,
    required this.onParamChanged,
  });

  final List<ParamEntry> entries;
  final double weightKg;
  final ParamValues values;
  final ValueChanged<double> onWeightChanged;
  final void Function(String id, double value) onParamChanged;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
      children: [
        for (final entry in entries)
          switch (entry) {
            WeightEntry() => ListTile(
              title: Text(context.l10n.commonWeight),
              trailing: Text(
                '${formatWeight(weightKg, locale: locale)} '
                '${context.l10n.watchUnitKg}',
              ),
              onTap: () => editWeight(
                context,
                weightKg: weightKg,
                onChanged: onWeightChanged,
              ),
            ),
            CustomParam(:final id, :final name) => ListTile(
              title: Text(name),
              trailing: Text(
                values[id] == null ? '—' : formatParamValue(values[id]!),
              ),
              onTap: () => editParam(
                context,
                param: entry,
                value: values[id],
                onChanged: (v) => onParamChanged(id, v),
              ),
            ),
          },
      ],
    );
  }
}
