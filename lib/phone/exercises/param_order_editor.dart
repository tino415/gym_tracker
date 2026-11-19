import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../data/exercise_params.dart';
import '../../l10n/l10n.dart';

const _uuid = Uuid();

class ParamOrderEditor extends StatelessWidget {
  const ParamOrderEditor({
    super.key,
    required this.order,
    required this.onChanged,
  });

  final List<ParamEntry> order;
  final ValueChanged<List<ParamEntry>> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.paramsTitle, style: Theme.of(context).textTheme.titleMedium),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorder: _reorder,
          children: [
            for (var i = 0; i < order.length; i++) _row(context, i, order[i]),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _add(context),
            icon: const Icon(Icons.add),
            label: Text(l10n.paramsAdd),
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, int index, ParamEntry entry) {
    final l10n = context.l10n;
    final caption = switch (index) {
      0 => l10n.paramsOnWatchFace,
      1 => l10n.paramsSwipePage,
      _ => null,
    };
    return ListTile(
      key: ValueKey(switch (entry) {
        WeightEntry() => 'weight',
        CustomParam(:final id) => id,
      }),
      contentPadding: EdgeInsets.zero,
      title: Text(switch (entry) {
        WeightEntry() => l10n.commonWeight,
        CustomParam(:final name) => name,
      }),
      subtitle: caption == null ? null : Text(caption),
      onTap: entry is CustomParam ? () => _rename(context, index, entry) : null,
      leading: ReorderableDragStartListener(
        index: index,
        child: const Icon(Icons.drag_handle),
      ),
      trailing: entry is CustomParam
          ? IconButton(
              onPressed: () => onChanged([...order]..removeAt(index)),
              icon: const Icon(Icons.close),
              tooltip: l10n.paramsRemove,
            )
          : null,
    );
  }

  void _reorder(int from, int to) {
    final next = [...order];
    final moved = next.removeAt(from);
    next.insert(to > from ? to - 1 : to, moved);
    onChanged(next);
  }

  Future<void> _add(BuildContext context) async {
    final name = await _askName(context, '');
    if (name == null) return;
    onChanged([...order, CustomParam(id: _uuid.v4(), name: name)]);
  }

  Future<void> _rename(
    BuildContext context,
    int index,
    CustomParam entry,
  ) async {
    final name = await _askName(context, entry.name);
    if (name == null) return;
    onChanged([...order]..[index] = entry.renamed(name));
  }

  Future<String?> _askName(BuildContext context, String initial) async {
    final controller = TextEditingController(text: initial);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.paramsName),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: ctx.l10n.paramsName),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(ctx.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(ctx.l10n.commonSave),
          ),
        ],
      ),
    );
    controller.dispose();
    return name == null || name.isEmpty ? null : name;
  }
}
