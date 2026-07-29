import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers.dart';
import '../../sync/sync_service.dart';
import '../account_action.dart';
import '../breakpoints.dart';
import '../list_empty_state.dart';
import '../wide_master_detail.dart';
import 'routine_edit_page.dart';
import 'routine_exercise_detail_page.dart';

/// Routines home. Three tiers:
/// - narrow (< [masterDetailBreakpoint]): single-pane list, pushes the editor
///   (and, from the editor, the per-exercise set editor) as full-screen routes.
/// - 2-pane ([masterDetailBreakpoint]..[threePaneBreakpoint]): list | detail;
///   selecting an exercise swaps the detail pane to the set editor (with a back
///   affordance to the routine editor). The list stays.
/// - 3-pane (>= [threePaneBreakpoint]): list | routine editor | set editor, all
///   visible; selecting an exercise fills the third column.
class RoutinesListPage extends ConsumerWidget {
  const RoutinesListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = MediaQuery.sizeOf(context).width >= masterDetailBreakpoint;
    if (wide) return const _RoutinesMasterDetail();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Routines'),
        actions: const [AccountAction()],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/routines/new'),
        child: const Icon(Icons.add),
      ),
      body: RefreshIndicator(
        // On the Firestore-direct web build there's no SyncService (Firestore
        // snapshots are already live); pull-to-refresh is a no-op there.
        onRefresh: () => ref.read(firestoreDirectProvider)
            ? Future<void>.value()
            : ref.read(syncServiceProvider).pushAll(),
        child: RoutinesListView(
          onSelect: (id) => context.push('/routines/$id'),
          alwaysScrollable: true,
        ),
      ),
    );
  }
}

/// The wide (2-pane / 3-pane) master-detail. Owns a single selection state —
/// which routine, and which exercise slot within it — that drives every tier.
class _RoutinesMasterDetail extends StatefulWidget {
  const _RoutinesMasterDetail();

  @override
  State<_RoutinesMasterDetail> createState() => _RoutinesMasterDetailState();
}

class _RoutinesMasterDetailState extends State<_RoutinesMasterDetail> {
  String? _routineId;
  bool _draft = false;

  /// Rebuild key for the routine editor. Bumped only on user-initiated routine
  /// switches — never on [_onRoutineCreated] — so persisting a draft in place
  /// doesn't tear down the editor mid-flow.
  int _epoch = 0;

  /// Selected routine-exercise slot (drives the set editor). Cleared whenever
  /// the routine selection changes.
  String? _reId;

  void _selectRoutine(String id) => setState(() {
        _routineId = id;
        _draft = false;
        _reId = null;
        _epoch++;
      });

  void _newDraft() => setState(() {
        _routineId = null;
        _draft = true;
        _reId = null;
        _epoch++;
      });

  void _clearRoutine() => setState(() {
        _routineId = null;
        _draft = false;
        _reId = null;
        _epoch++;
      });

  void _onRoutineCreated(String id) => setState(() {
        _routineId = id;
        _draft = false;
      });

  void _selectExercise(String reId) => setState(() => _reId = reId);
  void _clearExercise() => setState(() => _reId = null);

  bool get _hasRoutine => _routineId != null || _draft;

  @override
  Widget build(BuildContext context) {
    final threePane =
        MediaQuery.sizeOf(context).width >= threePaneBreakpoint;
    final showSetEditor = _reId != null && _routineId != null;

    final routineEditor = _hasRoutine
        ? RoutineEditPage(
            key: ValueKey(_epoch),
            routineId: _routineId,
            embedded: true,
            onDeleted: _clearRoutine,
            onCreated: _onRoutineCreated,
            onSelectExercise: _selectExercise,
            selectedExerciseId: _reId,
          )
        : const MasterDetailPlaceholder(
            icon: Icons.fitness_center,
            label: 'Select a routine, or + to create one.',
          );

    Widget setEditor({required bool showBack}) => showSetEditor
        ? RoutineExerciseDetailPage(
            key: ValueKey(_reId),
            routineId: _routineId!,
            routineExerciseId: _reId!,
            embedded: true,
            showBack: showBack,
            onClose: _clearExercise,
          )
        : const MasterDetailPlaceholder(
            icon: Icons.repeat,
            label: 'Select an exercise to edit its sets.',
          );

    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _listPane(context),
          const VerticalDivider(width: 1),
          if (threePane) ...[
            Expanded(child: routineEditor),
            const VerticalDivider(width: 1),
            Expanded(child: setEditor(showBack: false)),
          ] else
            // 2-pane: keep the routine editor alive (state preserved) and stack
            // the set editor over it when an exercise is selected.
            Expanded(
              child: IndexedStack(
                index: showSetEditor ? 1 : 0,
                children: [
                  routineEditor,
                  showSetEditor
                      ? setEditor(showBack: true)
                      : const SizedBox.shrink(),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _listPane(BuildContext context) {
    return SizedBox(
      width: 300,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Routines',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'New routine',
                  onPressed: _newDraft,
                  icon: const Icon(Icons.add),
                ),
                const AccountAction(),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: RoutinesListView(
              onSelect: _selectRoutine,
              selectedId: _routineId,
            ),
          ),
        ],
      ),
    );
  }
}

/// The list body itself — loading / error / empty / list of routines — shared by
/// the narrow full page and the wide master-detail pane. Selection is delegated
/// via [onSelect]; [selectedId] highlights the current row (master-detail only).
class RoutinesListView extends ConsumerWidget {
  const RoutinesListView({
    super.key,
    required this.onSelect,
    this.selectedId,
    this.alwaysScrollable = false,
  });

  final void Function(String syncId) onSelect;
  final String? selectedId;

  /// Force the list scrollable even when short, so a wrapping [RefreshIndicator]
  /// can be pulled on the narrow page. Off in the wide pane (no pull-to-refresh).
  final bool alwaysScrollable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routinesAsync = ref.watch(routineSummariesStreamProvider);
    final physics =
        alwaysScrollable ? const AlwaysScrollableScrollPhysics() : null;
    return routinesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          ListView(physics: physics, children: [Center(child: Text('Error: $e'))]),
      data: (summaries) {
        if (summaries.isEmpty) {
          return CustomScrollView(
            physics: physics,
            slivers: [
              const ListEmptyState(
                icon: Icons.fitness_center,
                title: 'No routines yet',
                lines: [
                  'Tap + to design your first routine.',
                  'Pull down to sync with the watch.',
                ],
              ).asSliver(),
            ],
          );
        }
        return ListView.separated(
          physics: physics,
          itemCount: summaries.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final s = summaries[i];
            return ListTile(
              selected: s.routine.syncId == selectedId,
              title: Text(s.routine.name),
              subtitle: Text(
                s.exerciseCount == 1
                    ? '1 exercise'
                    : '${s.exerciseCount} exercises',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onSelect(s.routine.syncId),
            );
          },
        );
      },
    );
  }
}

