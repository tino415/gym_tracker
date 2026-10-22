import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

String formatKg(BuildContext context, double kg) {
  final locale = Localizations.localeOf(context).toString();
  final pattern = kg == kg.roundToDouble() ? '#0' : '#0.0';
  return NumberFormat(pattern, locale).format(kg);
}

double? parseDecimal(String text) =>
    double.tryParse(text.trim().replaceAll(',', '.'));
