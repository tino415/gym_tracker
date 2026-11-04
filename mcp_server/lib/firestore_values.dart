import 'package:googleapis/firestore/v1.dart' as fs;

Map<String, Object?> documentToJson(fs.Document document) => {
  for (final field in (document.fields ?? {}).entries)
    field.key: valueToJson(field.value),
};

Object? valueToJson(fs.Value value) {
  if (value.booleanValue != null) {
    return value.booleanValue;
  }
  if (value.integerValue != null) return int.parse(value.integerValue!);
  if (value.doubleValue != null) return value.doubleValue;
  if (value.stringValue != null) return value.stringValue;
  if (value.timestampValue != null) return value.timestampValue;
  final map = value.mapValue;
  if (map != null) {
    return {
      for (final field in (map.fields ?? {}).entries)
        field.key: valueToJson(field.value),
    };
  }
  final array = value.arrayValue;
  if (array != null) {
    return [for (final v in array.values ?? []) valueToJson(v)];
  }
  return null;
}

fs.Document jsonToDocument(Map<String, Object?> json) => fs.Document(
  fields: {for (final e in json.entries) e.key: jsonToValue(e.value)},
);

fs.Value jsonToValue(Object? json) => switch (json) {
  null => fs.Value(nullValue: 'NULL_VALUE'),
  bool b => fs.Value(booleanValue: b),
  int i => fs.Value(integerValue: '$i'),
  double d => fs.Value(doubleValue: d),
  String s => fs.Value(stringValue: s),
  List l => fs.Value(
    arrayValue: fs.ArrayValue(values: [...l.map(jsonToValue)]),
  ),
  Map m => fs.Value(
    mapValue: fs.MapValue(
      fields: {
        for (final e in m.entries) e.key as String: jsonToValue(e.value),
      },
    ),
  ),
  _ => throw ArgumentError('Not a JSON value: $json'),
};
