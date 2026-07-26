import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers.dart';
import '../breakpoints.dart';
import '../wide_master_detail.dart';
import 'exercise_edit_page.dart';

/// Exercises home. Narrow: single-pane list that pushes the editor. Wide:
/// master-detail split with the editor inline (see [masterDetailBreakpoint]).
class ExercisesListPage extends ConsumerWidget {
  const ExercisesListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = MediaQuery.sizeOf(context).width >= masterDetailBreakpoint;
    if (wide) {
      return WideMasterDetail(
        title: 'Exercises',
        addTooltip: 'New exercise',
        onAdd: (api) async => api.newDraft(),
        listBuilder: (onSelect, selectedId) =>
            ExercisesListView(onSelect: onSelect, selectedId: selectedId),
        detailBuilder: (selectedId, isDraft, onDeleted, onCreated) =>
            ExerciseEditPage(
          exerciseId: selectedId,
          embedded: true,
          onDeleted: onDeleted,
          onCreated: onCreated,
        ),
        placeholder: const MasterDetailPlaceholder(
          icon: Icons.list_alt,
          label: 'Select an exercise, or + to create one.',
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Exercises')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/exercises/new'),
        child: const Icon(Icons.add),
      ),
      body: ExercisesListView(
        onSelect: (id) => context.push('/exercises/$id'),
      ),
    );
  }
}

/// List body — loading / error / empty / list of exercises — shared by the
/// narrow page and the wide pane. [selectedId] highlights the current row.
class ExercisesListView extends ConsumerWidget {
  const ExercisesListView({
    super.key,
    required this.onSelect,
    this.selectedId,
  });

  final void Function(String syncId) onSelect;
  final String? selectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exercisesAsync = ref.watch(exercisesWithMusclesStreamProvider);
    return exercisesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (exercises) {
        if (exercises.isEmpty) {
          return const _EmptyState();
        }
        return ListView.separated(
          itemCount: exercises.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final e = exercises[i];
            return ListTile(
              selected: e.exercise.syncId == selectedId,
              title: Text(e.exercise.name),
              subtitle: e.muscles.isEmpty
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final m in e.muscles) _MuscleTag(name: m.name),
                        ],
                      ),
                    ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onSelect(e.exercise.syncId),
            );
          },
        );
      },
    );
  }
}

class _MuscleTag extends StatelessWidget {
  const _MuscleTag({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        name,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSecondaryContainer,
            ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.list_alt,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            const Text(
              'No exercises yet',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap + to add your first one.',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}
