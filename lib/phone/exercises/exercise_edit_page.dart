import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/database.dart';
import '../../data/providers.dart';

class ExerciseEditPage extends ConsumerStatefulWidget {
  const ExerciseEditPage({super.key, this.exerciseId});

  final int? exerciseId;

  @override
  ConsumerState<ExerciseEditPage> createState() => _ExerciseEditPageState();
}

class _ExerciseEditPageState extends ConsumerState<ExerciseEditPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  Exercise? _loaded;
  bool _initializing = true;

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
    final db = ref.read(databaseProvider);
    final list = await db.watchExercises().first;
    final found = list.where((e) => e.id == widget.exerciseId).firstOrNull;
    setState(() {
      _loaded = found;
      _nameController.text = found?.name ?? '';
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
    final db = ref.read(databaseProvider);
    final name = _nameController.text.trim();
    try {
      if (_loaded == null) {
        await db.createExercise(name);
      } else {
        await db.renameExercise(_loaded!.id, name);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save: $e')));
      return;
    }
    if (!mounted) return;
    context.pop();
  }

  Future<void> _delete() async {
    if (_loaded == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete exercise?'),
        content: Text(
          'Delete "${_loaded!.name}"? Workouts that reference it will need to be edited.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(databaseProvider).deleteExercise(_loaded!.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not delete: $e')));
      return;
    }
    if (!mounted) return;
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final isEdit = _loaded != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? 'Edit exercise' : 'New exercise'),
        actions: [
          if (isEdit)
            IconButton(
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _save(),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Name is required';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _save, child: const Text('Save')),
            ],
          ),
        ),
      ),
    );
  }
}
