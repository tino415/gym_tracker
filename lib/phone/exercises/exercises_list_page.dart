import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers.dart';
import '../account_action.dart';
import '../breakpoints.dart';
import '../list_empty_state.dart';
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
      appBar: AppBar(
        title: const Text('Exercises'),
        actions: const [AccountAction()],
      ),
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

/// List body — loading / error / empty / searchable list of exercises — shared
/// by the narrow page and the wide pane. [selectedId] highlights the current
/// row. The name filter lives here (not in the app bar) so both tiers get it
/// from one place; it mirrors the exercise picker's search field.
class ExercisesListView extends ConsumerStatefulWidget {
  const ExercisesListView({
    super.key,
    required this.onSelect,
    this.selectedId,
  });

  final void Function(String syncId) onSelect;
  final String? selectedId;

  @override
  ConsumerState<ExercisesListView> createState() => _ExercisesListViewState();
}

class _ExercisesListViewState extends ConsumerState<ExercisesListView> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _clearQuery() {
    _searchController.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    final exercisesAsync = ref.watch(exercisesWithMusclesStreamProvider);
    return exercisesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (exercises) {
        // Nothing to search through yet — show the plain empty state instead of
        // a search box over an empty list.
        if (exercises.isEmpty) {
          return const ListEmptyState(
            icon: Icons.list_alt,
            title: 'No exercises yet',
            lines: ['Tap + to add your first one.'],
          );
        }

        final q = _query.trim().toLowerCase();
        final filtered = q.isEmpty
            ? exercises
            : exercises
                .where((e) => e.exercise.name.toLowerCase().contains(q))
                .toList();

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search exercises',
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.clear),
                          onPressed: _clearQuery,
                        ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: filtered.isEmpty
                  ? ListEmptyState(
                      icon: Icons.search_off,
                      title: 'No exercises match',
                      lines: ['Nothing named “${_query.trim()}”.'],
                    )
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final e = filtered[i];
                        return ListTile(
                          selected: e.exercise.syncId == widget.selectedId,
                          title: Text(e.exercise.name),
                          subtitle: e.muscles.isEmpty
                              ? null
                              : Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Wrap(
                                    spacing: 4,
                                    runSpacing: 4,
                                    children: [
                                      for (final m in e.muscles)
                                        _MuscleTag(name: m.name),
                                    ],
                                  ),
                                ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => widget.onSelect(e.exercise.syncId),
                        );
                      },
                    ),
            ),
          ],
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

