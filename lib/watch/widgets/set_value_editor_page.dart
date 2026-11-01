import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import 'round_safe_area.dart';

const _stepButtonSize = 64.0;

Future<T?> editSetValue<T extends num>(
  BuildContext context, {
  required T value,
  required T step,
  required T min,
  required String Function(T) formatter,
  required String unit,
}) {
  return Navigator.of(context).push<T>(
    MaterialPageRoute(
      builder: (_) => SetValueEditorPage<T>(
        value: value,
        step: step,
        min: min,
        formatter: formatter,
        unit: unit,
      ),
    ),
  );
}

class SetValueEditorPage<T extends num> extends StatefulWidget {
  const SetValueEditorPage({
    super.key,
    required this.value,
    required this.step,
    required this.min,
    required this.formatter,
    required this.unit,
  });

  final T value;
  final T step;
  final T min;
  final String Function(T) formatter;
  final String unit;

  @override
  State<SetValueEditorPage<T>> createState() => _SetValueEditorPageState<T>();
}

class _SetValueEditorPageState<T extends num>
    extends State<SetValueEditorPage<T>> {
  late T _draft = widget.value;

  void _bump(int sign) {
    final next = (_draft + widget.step * sign) as T;
    if (next < widget.min) return;
    setState(() => _draft = next);
  }

  Future<void> _typeValue() async {
    final typed = await enterNumber<T>(
      context,
      initial: widget.formatter(_draft),
      suffix: widget.unit,
      isInt: _draft is int,
    );
    if (typed == null || typed < widget.min) return;
    setState(() => _draft = typed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRound = WatchShapeScope.of(context);
    return Scaffold(
      body: RoundSafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              InkWell(
                customBorder: const StadiumBorder(),
                onTap: _typeValue,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        widget.formatter(_draft),
                        style: theme.textTheme.headlineMedium,
                      ),
                      Text(
                        ' ${widget.unit}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _StepButton(icon: Icons.remove, onTap: () => _bump(-1)),
                  const SizedBox(width: 8),
                  _StepButton(icon: Icons.add, onTap: () => _bump(1)),
                ],
              ),
              const SizedBox(height: 6),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: isRound ? 32 : 0),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop<T>(_draft),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(36),
                    ),
                    child: Text(context.l10n.watchOk),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      shape: const CircleBorder(),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: _stepButtonSize,
          height: _stepButtonSize,
          child: Icon(icon, size: 28),
        ),
      ),
    );
  }
}

Future<T?> enterNumber<T extends num>(
  BuildContext context, {
  required String initial,
  required String? suffix,
  required bool isInt,
}) {
  return Navigator.of(context).push<T>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) =>
          _NumberEntryPage<T>(initial: initial, suffix: suffix, isInt: isInt),
    ),
  );
}

/// Custom numpad — Flutter's TextField is broken on Wear OS (the system
/// IME's batched edit operations don't propagate consistently, so backspace
/// + multi-digit typing get dropped). This page is fully self-contained:
/// no system keyboard, no InputConnection, just a string buffer that we
/// own and that the user mutates by tapping on-screen digits.
class _NumberEntryPage<T extends num> extends StatefulWidget {
  const _NumberEntryPage({
    required this.initial,
    required this.suffix,
    required this.isInt,
  });

  final String initial;
  final String? suffix;
  final bool isInt;

  @override
  State<_NumberEntryPage<T>> createState() => _NumberEntryPageState<T>();
}

class _NumberEntryPageState<T extends num> extends State<_NumberEntryPage<T>> {
  late String _buffer;
  // First digit press clears the pre-filled initial so people can type a
  // fresh value without having to backspace through it.
  bool _replaceOnNext = true;

  @override
  void initState() {
    super.initState();
    _buffer = widget.initial.replaceAll(',', '.');
  }

  void _onDigit(String d) {
    setState(() {
      if (_replaceOnNext) {
        _buffer = '';
        _replaceOnNext = false;
      }
      if (d == '.') {
        if (widget.isInt || _buffer.contains('.')) return;
        _buffer = _buffer.isEmpty ? '0.' : '$_buffer.';
        return;
      }
      _buffer = _buffer == '0' ? d : '$_buffer$d';
    });
  }

  String _decimalSeparator(BuildContext context) => NumberFormat.decimalPattern(
    Localizations.localeOf(context).toString(),
  ).symbols.DECIMAL_SEP;

  T? _parse() {
    if (_buffer.isEmpty) return null;
    if (widget.isInt) return int.tryParse(_buffer) as T?;
    return double.tryParse(_buffer) as T?;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final decimalSeparator = _decimalSeparator(context);
    final shown = _buffer.isEmpty
        ? '0'
        : _buffer.replaceAll('.', decimalSeparator);
    final display = widget.suffix == null ? shown : '$shown ${widget.suffix}';
    // The display row at the top and the OK button at the bottom need a
    // small chord inset on round watches so they don't bleed past the bezel.
    final isRound = WatchShapeScope.of(context);
    final topInset = isRound ? 24.0 : 0.0;
    final bottomInset = isRound ? 32.0 : 0.0;
    final vGap = isRound ? 20.0 : 4.0;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: RoundSafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: vGap),
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: topInset),
                child: SizedBox(
                  height: 40,
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        display,
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _Numpad(
                  isInt: widget.isInt,
                  decimalSeparator: decimalSeparator,
                  onDigit: _onDigit,
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: bottomInset),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _buffer.isEmpty
                        ? null
                        : () => Navigator.of(context).pop<T>(_parse()),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(30),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    child: Text(context.l10n.watchOk),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Numpad extends StatelessWidget {
  const _Numpad({
    required this.isInt,
    required this.decimalSeparator,
    required this.onDigit,
  });

  final bool isInt;
  final String decimalSeparator;
  final void Function(String) onDigit;

  @override
  Widget build(BuildContext context) {
    Widget key(String label, {VoidCallback? onTap}) => Expanded(
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Center(
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
        ),
      ),
    );
    Widget digit(String d) => key(d, onTap: () => onDigit(d));
    final dot = isInt
        ? const Expanded(child: SizedBox.shrink())
        : key(decimalSeparator, onTap: () => onDigit('.'));
    // The keypad's top/bottom rows are the worst-clipped — pull them off the
    // bezel just enough that the corner keys (3, 9, `.`, blank) fit inside
    // the inscribed circle. The middle band needs less inset but applying a
    // uniform value to the whole keypad is fine since the chord-aware padding
    // is small (~24 px on a 480 px round face).
    final hInset = WatchShapeScope.of(context) ? 24.0 : 0.0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: hInset),
      child: Column(
        children: [
          Expanded(child: Row(children: [digit('1'), digit('2'), digit('3')])),
          Expanded(child: Row(children: [digit('4'), digit('5'), digit('6')])),
          Expanded(child: Row(children: [digit('7'), digit('8'), digit('9')])),
          Expanded(
            child: Row(
              children: [
                dot,
                digit('0'),
                const Expanded(child: SizedBox.shrink()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
