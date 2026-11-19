import 'dart:convert';

import 'package:drift/drift.dart';

import 'exercise_params.dart';

class ParamOrderConverter extends TypeConverter<List<ParamEntry>, String> {
  const ParamOrderConverter();

  @override
  List<ParamEntry> fromSql(String fromDb) => decodeParamOrder(fromDb);

  @override
  String toSql(List<ParamEntry> value) => encodeParamOrder(value);
}

class ParamValuesConverter extends TypeConverter<ParamValues, String> {
  const ParamValuesConverter();

  @override
  ParamValues fromSql(String fromDb) => decodeParamValues(fromDb) ?? const {};

  @override
  String toSql(ParamValues value) => jsonEncode(value);
}
