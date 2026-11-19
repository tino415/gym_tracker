import 'package:flutter/material.dart';

import '../../data/database.dart' show exerciseKindTime;
import '../../data/exercise_params.dart';
import '../../l10n/l10n.dart';
import '../number_format.dart';

/// Values entered for a planned set. reps + weight for reps-kind; seconds +
/// optional weight for time-kind; plus a value per custom parameter filled in.
class SetValues {
  const SetValues({this.reps, this.weightKg, this.seconds, this.params});
  final int? reps;
  final double? weightKg;
  final int? seconds;
  final ParamValues? params;
}

/// Keyboard-first planned-set editor, shared by primary and alternative sets.
///
/// Autofocuses the first field, Tab moves between fields, Enter saves. In *add*
/// mode Enter is "Save & add another" — it persists the set and stays open with
/// the values kept and reselected, so a desktop user can enter a whole set
/// scheme (or several identical sets) without reopening the dialog; "Done"
/// closes. *Edit* mode saves the one set and closes. Owns its controllers
/// (disposed in [dispose]).
class SetEditorDialog extends StatefulWidget {
  const SetEditorDialog({
    super.key,
    required this.kind,
    required this.onAdd,
    required this.onUpdate,
    this.existingId,
    this.initialReps,
    this.initialWeightKg,
    this.initialSeconds,
    this.params = const [],
    this.initialParams,
  });

  final String kind;
  final List<CustomParam> params;
  final ParamValues? initialParams;

  /// Non-null puts the dialog in edit mode (save-and-close, no "add another").
  final String? existingId;
  final int? initialReps;
  final double? initialWeightKg;
  final int? initialSeconds;

  final Future<void> Function(SetValues values) onAdd;
  final Future<void> Function(String id, SetValues values) onUpdate;

  @override
  State<SetEditorDialog> createState() => _SetEditorDialogState();
}

class _SetEditorDialogState extends State<SetEditorDialog> {
  late final TextEditingController _reps =
      TextEditingController(text: widget.initialReps?.toString() ?? '10');
  late final TextEditingController _weight = TextEditingController(
      text: widget.initialWeightKg?.toStringAsFixed(0) ?? '20');
  late final TextEditingController _seconds =
      TextEditingController(text: widget.initialSeconds?.toString() ?? '30');
  late final Map<String, TextEditingController> _paramFields = {
    for (final p in widget.params)
      p.id: TextEditingController(
        text: widget.initialParams?[p.id] == null
            ? ''
            : formatParamValue(widget.initialParams![p.id]!),
      ),
  };
  final _firstFocus = FocusNode();
  bool _busy = false;
  int _added = 0;

  bool get _isTime => widget.kind == exerciseKindTime;
  bool get _isEdit => widget.existingId != null;

  @override
  void dispose() {
    _reps.dispose();
    _weight.dispose();
    _seconds.dispose();
    for (final c in _paramFields.values) {
      c.dispose();
    }
    _firstFocus.dispose();
    super.dispose();
  }

  ParamValues? _readParams() {
    final values = {
      for (final e in _paramFields.entries) e.key: ?parseDecimal(e.value.text),
    };
    return values.isEmpty ? null : values;
  }

  /// Parse the fields, or null if invalid (leaves the dialog open).
  SetValues? _read() {
    final weight = parseDecimal(_weight.text);
    final params = _readParams();
    if (_isTime) {
      final s = int.tryParse(_seconds.text.trim());
      if (s == null || s <= 0) return null;
      return SetValues(seconds: s, weightKg: weight, params: params);
    }
    final r = int.tryParse(_reps.text.trim());
    if (r == null || weight == null) return null;
    return SetValues(reps: r, weightKg: weight, params: params);
  }

  Future<void> _save({required bool another}) async {
    if (_busy) return;
    final values = _read();
    if (values == null) return;
    setState(() => _busy = true);
    try {
      if (_isEdit) {
        await widget.onUpdate(widget.existingId!, values);
        if (mounted) Navigator.of(context).pop();
        return;
      }
      await widget.onAdd(values);
      _added++;
      if (!mounted) return;
      if (another) {
        // Keep the values and reselect the first field so repeated Enter adds
        // identical sets and Tab tweaks them — the fast desktop path.
        setState(() => _busy = false);
        _firstFocus.requestFocus();
        final c = _isTime ? _seconds : _weight;
        c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
      } else {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.routineSetEditorFailed('$e'))));
    }
  }

  Widget _field(
    TextEditingController controller, {
    required String label,
    String? suffix,
    bool decimal = false,
    bool autofocus = false,
  }) =>
      TextField(
        controller: controller,
        focusNode: autofocus ? _firstFocus : null,
        autofocus: autofocus,
        enabled: !_busy,
        keyboardType: TextInputType.numberWithOptions(decimal: decimal),
        textInputAction:
            _isEdit ? TextInputAction.done : TextInputAction.next,
        onSubmitted: (_) => _save(another: !_isEdit),
        decoration: InputDecoration(labelText: label, suffixText: suffix),
      );

  @override
  Widget build(BuildContext context) {
    final title = _isEdit
        ? context.l10n.routineSetEditTitle
        : _added == 0
            ? context.l10n.routineSetNewTitle
            : context.l10n.routineSetNewTitleAdded(_added);
    return AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...(_isTime
            ? [
                _field(_seconds,
                    label: context.l10n.commonSeconds, suffix: context.l10n.commonUnitSeconds, autofocus: true),
                const SizedBox(height: 8),
                _field(_weight,
                    label: context.l10n.routineSetWeightOptional, suffix: context.l10n.commonUnitKg, decimal: true),
              ]
            : [
                _field(_weight,
                    label: context.l10n.commonWeight,
                    suffix: context.l10n.commonUnitKg,
                    decimal: true,
                    autofocus: true),
                const SizedBox(height: 8),
                _field(_reps, label: context.l10n.commonReps),
              ]),
          for (final p in widget.params) ...[
            const SizedBox(height: 8),
            _field(
              _paramFields[p.id]!,
              label: context.l10n.paramsValueOptional(p.name),
              decimal: true,
            ),
          ],
        ],
      ),
      actions: _isEdit
          ? [
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: Text(context.l10n.commonCancel),
              ),
              FilledButton(
                onPressed: _busy ? null : () => _save(another: false),
                child: Text(context.l10n.commonSave),
              ),
            ]
          : [
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: Text(context.l10n.commonDone),
              ),
              FilledButton(
                onPressed: _busy ? null : () => _save(another: true),
                child: Text(context.l10n.routineSetSaveAndAdd),
              ),
            ],
    );
  }
}
