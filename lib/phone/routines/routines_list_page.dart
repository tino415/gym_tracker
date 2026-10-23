import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers.dart';
import '../../l10n/l10n.dart';
import '../../sync/sync_service.dart';
import '../account_action.dart';
import '../breakpoints.dart';
import '../list_empty_state.dart';
import '../run/workout_run_page.dart';
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
        title: Text(context.l10n.routinesTitle),
        actions: const [AccountAction()],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/routines/new'),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          const ResumeWorkoutBanner(),
          Expanded(
            child: RefreshIndicator(
              // On the Firestore-direct web build there's no SyncService
              // (Firestore snapshots are already live); pull-to-refresh is a
              // no-op there.
              onRefresh: () => ref.read(firestoreDirectProvider)
                  ? Future<void>.value()
                  : ref.read(syncServiceProvider).pushAll(),
              child: RoutinesListView(
                onSelect: (id) => context.push('/routines/$id'),
                alwaysScrollable: true,
              ),
            ),
          ),
        ],
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
            onExerciseRemoved: _clearExercise,
          )
        : MasterDetailPlaceholder(
            icon: Icons.fitness_center,
            label: context.l10n.routinesSelectPrompt,
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
        : MasterDetailPlaceholder(
            icon: Icons.repeat,
            label: context.l10n.routineSelectExercisePrompt,
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
                    context.l10n.routinesTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: context.l10n.routineNew,
                  onPressed: _newDraft,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          const ResumeWorkoutBanner(),
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

/// Drag a routine row right-to-left to start a workout from it.
///
/// A deliberate gesture rather than a button on the row: a tap target sitting
/// beside the row's own tap target was too easy to hit by accident when you
/// only meant to open the routine. The discoverable path is the "Start workout"
/// button inside the routine editor; this is the shortcut once you know it.
///
/// It never actually dismisses — [confirmDismiss] navigates and returns false,
/// so the row springs back and is still there when you come out of the workout.
class _SwipeToStart extends StatelessWidget {
  const _SwipeToStart({required this.routineId, required this.child});

  final String routineId;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey('swipe-to-start-$routineId'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        context.push('/run/$routineId');
        return false;
      },
      background: ColoredBox(
        color: scheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Icon(Icons.play_arrow, color: scheme.onPrimaryContainer),
              const SizedBox(width: 8),
              Text(
                context.l10n.routineSwipeStart,
                style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
      child: child,
    );
  }
}

/// Offers to pick up an unfinished workout. Hidden when there is none, and on
/// web where the run flow isn't offered at all.
///
/// A tombstoned workout keeps its null `endedAt`, but `watchInProgressWorkout`
/// already filters those out — otherwise an abandoned-and-deleted session would
/// offer Resume forever.
class ResumeWorkoutBanner extends ConsumerWidget {
  const ResumeWorkoutBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!runFlowAvailable) return const SizedBox.shrink();
    final workout = ref.watch(inProgressWorkoutStreamProvider).valueOrNull;
    if (workout == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primaryContainer,
      child: InkWell(
        onTap: () => context.push('/run/resume/${workout.syncId}'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Icon(Icons.play_circle_outline, color: scheme.onPrimaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.routineWorkoutInProgress,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                    Text(
                      workout.routineName ?? context.l10n.routineAdHocWorkout,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onPrimaryContainer),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => context.push('/run/resume/${workout.syncId}'),
                child: Text(context.l10n.routineResume),
              ),
            ],
          ),
        ),
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
          ListView(physics: physics, children: [Center(child: Text(context.l10n.commonError('$e')))]),
      data: (summaries) {
        if (summaries.isEmpty) {
          return CustomScrollView(
            physics: physics,
            slivers: [
              ListEmptyState(
                icon: Icons.fitness_center,
                title: context.l10n.routinesEmptyTitle,
                lines: [
                  context.l10n.routinesEmptyLine1,
                  context.l10n.routinesEmptyLine2,
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
            final tile = ListTile(
              selected: s.routine.syncId == selectedId,
              title: Text(s.routine.name),
              subtitle: Text(
                context.l10n.routineExerciseCount(s.exerciseCount),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onSelect(s.routine.syncId),
            );
            // Nothing to run in an empty routine, and web doesn't offer the
            // run flow at all.
            if (!runFlowAvailable || s.exerciseCount == 0) return tile;
            return _SwipeToStart(
              routineId: s.routine.syncId,
              child: tile,
            );
          },
        );
      },
    );
  }
}

