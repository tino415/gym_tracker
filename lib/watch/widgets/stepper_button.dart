import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import 'round_safe_area.dart';

class StepperValue<T extends num> extends StatelessWidget {
  const StepperValue({
    super.key,
    required this.value,
    required this.step,
    required this.onChanged,
    required this.formatter,
    this.min,
    this.suffix,
  });

  final T value;
  final T step;
  final ValueChanged<T> onChanged;
  final String Function(T) formatter;
  final T? min;
  final String? suffix;

  void _bump(int sign) {
    final next = (value + step * sign) as T;
    if (min != null && next < min!) return;
    onChanged(next);
  }

  Future<void> _editTyped(BuildContext context) async {
    final isInt = value is int;
    final result = await Navigator.of(context).push<T>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _NumberEntryPage<T>(
          initial: formatter(value),
          suffix: suffix,
          isInt: isInt,
        ),
      ),
    );
    if (result == null) return;
    if (min != null && result < min!) return;
    onChanged(result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Reserve a fixed slot for the value so the +/- buttons don't shift
    // when the digit count changes. 44 px fits "100" at titleMedium with
    // tight margins on either side.
    final valueText = SizedBox(
      width: 44,
      child: Text(
        formatter(value),
        textAlign: TextAlign.center,
        style: theme.textTheme.titleMedium?.copyWith(height: 1.0),
      ),
    );
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _RoundButton(icon: Icons.remove, onTap: () => _bump(-1)),
        InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => _editTyped(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: valueText,
          ),
        ),
        _RoundButton(icon: Icons.add, onTap: () => _bump(1)),
      ],
    );
    if (suffix == null) return row;
    // Pull the unit caption up under the value glyphs — without the negative
    // offset, Text's intrinsic ascent/descent leaves a visible gap below the
    // 36 px button row.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        Transform.translate(
          offset: const Offset(0, -8),
          child: Text(
            suffix!,
            style: theme.textTheme.labelSmall?.copyWith(
              height: 1.0,
              color: theme.colorScheme.outline,
            ),
          ),
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.onTap});

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
        child: SizedBox(width: 36, height: 36, child: Icon(icon, size: 18)),
      ),
    );
  }
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

  String _decimalSeparator(BuildContext context) =>
      NumberFormat.decimalPattern(
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
                      child: Text(display, style: theme.textTheme.headlineSmall),
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
