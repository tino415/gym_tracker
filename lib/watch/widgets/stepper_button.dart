import 'package:flutter/material.dart';

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _RoundButton(
          icon: Icons.remove,
          onTap: () => _bump(-1),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                formatter(value),
                style: theme.textTheme.headlineMedium,
              ),
              if (suffix != null)
                Text(
                  suffix!,
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
        ),
        _RoundButton(
          icon: Icons.add,
          onTap: () => _bump(1),
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
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(icon, size: 22),
        ),
      ),
    );
  }
}
