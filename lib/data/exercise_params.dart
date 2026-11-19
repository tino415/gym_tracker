import 'dart:convert';

/// One entry of an exercise's ordered parameter list. Weight is always in the
/// list, in the place the user ordered it; reps and time are not entries, they
/// stay the main value of a set.
sealed class ParamEntry {
  const ParamEntry();
}

final class WeightEntry extends ParamEntry {
  const WeightEntry();

  @override
  bool operator ==(Object other) => other is WeightEntry;

  @override
  int get hashCode => 'weight'.hashCode;
}

final class CustomParam extends ParamEntry {
  const CustomParam({required this.id, required this.name});

  final String id;
  final String name;

  CustomParam renamed(String name) => CustomParam(id: id, name: name);

  @override
  bool operator ==(Object other) =>
      other is CustomParam && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// Values keyed by [CustomParam.id]. Weight is not in here: it keeps its own
/// column on every table that carries a target or an actual.
typedef ParamValues = Map<String, double>;

const List<ParamEntry> defaultParamOrder = [WeightEntry()];

const _weightKey = 'builtin';
const _weightValue = 'weight';

/// The single place an order is parsed: a list without Weight reads as having
/// it first, so `'[]'` (the column default) is `[weight]`.
List<ParamEntry> decodeParamOrder(String? json) {
  final decoded = json == null || json.isEmpty
      ? const []
      : jsonDecode(json) as List<dynamic>;
  final entries = <ParamEntry>[
    for (final raw in decoded.cast<Map<String, dynamic>>())
      if (raw[_weightKey] == _weightValue)
        const WeightEntry()
      else
        CustomParam(id: raw['id'] as String, name: raw['name'] as String),
  ];
  if (entries.any((e) => e is WeightEntry)) return entries;
  return [const WeightEntry(), ...entries];
}

String encodeParamOrder(List<ParamEntry> order) => jsonEncode([
  for (final entry in order)
    switch (entry) {
      WeightEntry() => {_weightKey: _weightValue},
      CustomParam(:final id, :final name) => {'id': id, 'name': name},
    },
]);

List<Map<String, dynamic>> paramOrderToJson(List<ParamEntry> order) =>
    (jsonDecode(encodeParamOrder(order)) as List).cast<Map<String, dynamic>>();

List<ParamEntry> paramOrderFromJson(Object? json) =>
    decodeParamOrder(json == null ? null : jsonEncode(json));

ParamValues? decodeParamValues(String? json) {
  if (json == null || json.isEmpty) return null;
  final decoded = jsonDecode(json) as Map<String, dynamic>;
  if (decoded.isEmpty) return null;
  return {
    for (final e in decoded.entries) e.key: (e.value as num).toDouble(),
  };
}

String? encodeParamValues(ParamValues? values) =>
    values == null || values.isEmpty ? null : jsonEncode(values);

ParamValues? paramValuesFromJson(Object? json) => json == null
    ? null
    : decodeParamValues(jsonEncode(json));

extension ParamOrderReading on List<ParamEntry> {
  Iterable<CustomParam> get custom => whereType<CustomParam>();

  bool get hasCustom => any((e) => e is CustomParam);

  /// What the watch face shows beside the main value.
  ParamEntry get onFace => first;

  /// The third page: every entry but the one on the face.
  List<ParamEntry> get onSwipePage => skip(1).toList();
}

/// Displays a parameter value without a trailing `.0`.
String formatParamValue(double value) =>
    value == value.roundToDouble() ? value.toInt().toString() : '$value';

/// The editor's step: 0.5 when the value carries a fraction, else 1.
double paramStep(double? value) =>
    value != null && value != value.roundToDouble() ? 0.5 : 1;

/// Values with entries of [kept] only, null when none is left.
ParamValues? keepOnly(ParamValues? values, Set<String> kept) {
  if (values == null) return null;
  final filtered = {
    for (final e in values.entries)
      if (kept.contains(e.key)) e.key: e.value,
  };
  return filtered.isEmpty ? null : filtered;
}

/// Values by parameter name, for readers that never see ids; null when none.
Map<String, double>? namedParamValues(
  ParamValues? values,
  List<ParamEntry> order,
) {
  final named = {for (final p in order.custom) p.name: ?values?[p.id]};
  return named.isEmpty ? null : named;
}

String paramLabel(ParamValues? values, List<ParamEntry> order) => [
  for (final p in order.custom)
    if (values?[p.id] != null) '${p.name} ${formatParamValue(values![p.id]!)}',
].join(' · ');
