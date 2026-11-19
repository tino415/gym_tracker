import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:flutter/foundation.dart' show listEquals;

import '../../data/database.dart';
import '../../data/providers.dart';
import '../../l10n/l10n.dart';
import 'figure/exercise_visual.dart';
import 'muscle_selector.dart';
import 'param_order_editor.dart';

class ExerciseEditPage extends ConsumerStatefulWidget {
  const ExerciseEditPage({
    super.key,
    this.exerciseId,
    this.embedded = false,
    this.onDeleted,
    this.onCreated,
  });

  final String? exerciseId;

  /// Hosted in the wide master-detail pane rather than pushed as a route: no
  /// back stack, so save/delete report out via callbacks instead of popping.
  final bool embedded;

  /// Called when an embedded editor deletes its exercise (clears the selection).
  final VoidCallback? onDeleted;

  /// Called with the syncId after a save so the host can track/highlight it.
  final ValueChanged<String>? onCreated;

  @override
  ConsumerState<ExerciseEditPage> createState() => _ExerciseEditPageState();
}

class _ExerciseEditPageState extends ConsumerState<ExerciseEditPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  String _kind = exerciseKindReps;
  List<ParamEntry> _params = defaultParamOrder;
  Exercise? _loaded;
  bool _initializing = true;
  // Muscle ids currently selected for the exercise being edited. Resolved from
  // the join table on load; replaced wholesale on save.
  final Set<String> _selectedMuscleIds = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.exerciseId == null) {
      setState(() => _initializing = false);
      return;
    }
    final db = ref.read(exerciseRepositoryProvider);
    final list = await db.watchExercises().first;
    final found = list.where((e) => e.syncId == widget.exerciseId).firstOrNull;
    final mus = found == null
        ? const <Muscle>[]
        : await db.musclesForExercise(found.syncId);
    setState(() {
      _loaded = found;
      _nameController.text = found?.name ?? '';
      _kind = found?.kind ?? exerciseKindReps;
      _params = found?.params ?? defaultParamOrder;
      _selectedMuscleIds
        ..clear()
        ..addAll(mus.map((m) => m.syncId));
      _initializing = false;
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final db = ref.read(exerciseRepositoryProvider);
    final name = _nameController.text.trim();
    try {
      final Exercise exercise;
      if (_loaded == null) {
        exercise = await db.createExercise(name, kind: _kind);
      } else {
        await db.renameExercise(_loaded!.syncId, name);
        if (_loaded!.kind != _kind) {
          await db.setExerciseKind(_loaded!.syncId, _kind);
        }
        exercise = _loaded!;
      }
      if (!listEquals(exercise.params, _params)) {
        await db.setExerciseParams(exercise.syncId, _params);
      }
      await db.setExerciseMuscles(exercise.syncId, _selectedMuscleIds.toList());
      if (!mounted) return;
      if (widget.embedded) {
        // Stay in the pane on the now-persisted exercise; report the id up so
        // the list highlights it.
        setState(() => _loaded = exercise);
        widget.onCreated?.call(exercise.syncId);
      } else {
        context.pop();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.exerciseSaveError('$e'))));
      return;
    }
  }

  Future<void> _delete() async {
    if (_loaded == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.exerciseDeleteTitle),
        content: Text(ctx.l10n.exerciseDeleteBody(_loaded!.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(ctx.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(ctx.l10n.commonDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(exerciseRepositoryProvider).deleteExercise(_loaded!.syncId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.exerciseDeleteError('$e'))));
      return;
    }
    if (!mounted) return;
    if (widget.embedded) {
      widget.onDeleted?.call();
    } else {
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final isEdit = _loaded != null;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: Text(isEdit ? context.l10n.exerciseEdit : context.l10n.exerciseNew),
        actions: [
          if (isEdit)
            IconButton(
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
              tooltip: context.l10n.commonDelete,
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
              SizedBox(
                height: 200,
                child: Center(
                  child: ExerciseVisual(
                    exerciseId: _loaded?.syncId,
                    highlighted: _selectedMuscleIds,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: context.l10n.commonName,
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _save(),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return context.l10n.commonNameRequired;
                  return null;
                },
              ),
              const SizedBox(height: 16),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: exerciseKindReps,
                    label: Text(context.l10n.commonReps),
                    icon: Icon(Icons.repeat),
                  ),
                  ButtonSegment(
                    value: exerciseKindTime,
                    label: Text(context.l10n.commonTime),
                    icon: Icon(Icons.timer_outlined),
                  ),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
              const SizedBox(height: 16),
              ParamOrderEditor(
                order: _params,
                onChanged: (next) => setState(() => _params = next),
              ),
              const SizedBox(height: 16),
              MuscleSelector(
                selectedIds: _selectedMuscleIds,
                onToggled: (id) => setState(() {
                  if (!_selectedMuscleIds.add(id)) {
                    _selectedMuscleIds.remove(id);
                  }
                }),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _save, child: Text(context.l10n.commonSave)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

