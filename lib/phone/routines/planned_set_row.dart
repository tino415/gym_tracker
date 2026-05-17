import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/database.dart';

class PlannedSetRow extends StatefulWidget {
  const PlannedSetRow({
    super.key,
    required this.setIndex,
    required this.plannedSet,
    required this.onChanged,
    required this.onDelete,
  });

  final int setIndex;
  final PlannedSet plannedSet;
  final void Function(int reps, double weightKg) onChanged;
  final VoidCallback onDelete;

  @override
  State<PlannedSetRow> createState() => _PlannedSetRowState();
}

class _PlannedSetRowState extends State<PlannedSetRow> {
  late final TextEditingController _repsController;
  late final TextEditingController _weightController;

  @override
  void initState() {
    super.initState();
    _repsController = TextEditingController(
      text: widget.plannedSet.targetReps.toString(),
    );
    _weightController = TextEditingController(
      text: _formatWeight(widget.plannedSet.targetWeightKg),
    );
  }

  @override
  void didUpdateWidget(covariant PlannedSetRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newReps = widget.plannedSet.targetReps.toString();
    final newWeight = _formatWeight(widget.plannedSet.targetWeightKg);
    if (_repsController.text != newReps) _repsController.text = newReps;
    if (_weightController.text != newWeight) _weightController.text = newWeight;
  }

  @override
  void dispose() {
    _repsController.dispose();
    _weightController.dispose();
    super.dispose();
  }

  String _formatWeight(double w) {
    return w == w.roundToDouble() ? w.toStringAsFixed(0) : w.toString();
  }

  void _commit() {
    final reps =
        int.tryParse(_repsController.text.trim()) ??
        widget.plannedSet.targetReps;
    final weight =
        double.tryParse(_weightController.text.trim()) ??
        widget.plannedSet.targetWeightKg;
    if (reps != widget.plannedSet.targetReps ||
        weight != widget.plannedSet.targetWeightKg) {
      widget.onChanged(reps, weight);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Text(
              '${widget.setIndex + 1}.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          Expanded(
            child: TextField(
              controller: _weightController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: false,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
              ],
              decoration: const InputDecoration(labelText: 'kg', isDense: true),
              onEditingComplete: _commit,
              onTapOutside: (_) => _commit(),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('×'),
          ),
          Expanded(
            child: TextField(
              controller: _repsController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'reps',
                isDense: true,
              ),
              onEditingComplete: _commit,
              onTapOutside: (_) => _commit(),
            ),
          ),
          IconButton(
            onPressed: widget.onDelete,
            icon: const Icon(Icons.close),
            tooltip: 'Remove set',
          ),
        ],
      ),
    );
  }
}
