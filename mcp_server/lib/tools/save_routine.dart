import 'package:gym_tracker/data/exercise_kind.dart';
import 'package:gym_tracker/data/exercise_params.dart';
import 'package:gym_tracker/data/muscle_seeds.dart';
import 'package:gym_tracker/sync/sync_dtos.dart';
import 'package:mcp_dart/mcp_dart.dart';

import '../user_scope.dart';
import 'muscles.dart';
import 'read_tool.dart';
import 'routine_json.dart';

void registerSaveRoutine(
  McpServer server,
  ToolContext context, {
  required DateTime Function() now,
  required String Function() newId,
}) {
  registerWriteTool(
    server,
    context,
    name: 'save_routine',
    title: 'Save a routine',
    description:
        'Creates a routine, or replaces one whole. To change a routine, read '
        'it with get_routine, change that answer and send it back as routine, '
        'keeping its id, version, slotId and alternativeId values. Leave out '
        'id to create a routine. Each exercise names an exerciseId from '
        'find_exercises or get_routine, or a newExercise to add to the '
        'library. Limits: 50 exercises, 20 sets and 10 alternatives each, '
        'names of 1 to 100 characters, reps 1 to 1000, seconds 1 to 86400, '
        'weightKg 0 to 1000, restSeconds 0 to 3600 (default 90). It cannot '
        'delete a routine, rename an exercise or change its kind.',
    input: {'routine': _draftSchema},
    required: ['routine'],
    output: {'routine': routineSchema},
    answer: (args) async {
      final draft = _RoutineDraft.parse(args['routine']);
      final saved = await _RoutineSave(
        context.scope,
        now: now,
        newId: newId,
      ).save(draft);
      return ToolAnswer(
        'Saved at version ${saved.version}. ${routineSummary(saved)}',
        {'routine': routineJson(saved)},
      );
    },
  );
}

final _setSchema = JsonSchema.object(
  properties: {
    'reps': JsonSchema.integer(description: 'For a reps exercise.'),
    'weightKg': JsonSchema.number(),
    'seconds': JsonSchema.integer(description: 'For a time exercise.'),
    'parameters': JsonSchema.object(
      description: "Values of the exercise's custom parameters, by name.",
    ),
  },
);

final _newExerciseSchema = JsonSchema.object(
  description: 'An exercise to add to the library.',
  properties: {
    'name': JsonSchema.string(),
    'kind': JsonSchema.string(enumValues: [exerciseKindReps, exerciseKindTime]),
    'muscles': JsonSchema.array(
      description: 'Any of: ${muscleSeeds.join(', ')}.',
      items: JsonSchema.string(),
    ),
  },
  required: ['name', 'kind'],
);

final _draftSchema = JsonSchema.object(
  properties: {
    'id': JsonSchema.string(description: 'Leave out to create a routine.'),
    'version': JsonSchema.integer(
      description: 'The version that was read. Required with id.',
    ),
    'name': JsonSchema.string(),
    'exercises': JsonSchema.array(
      items: JsonSchema.object(
        properties: {
          'slotId': JsonSchema.string(
            description: 'Keep it to keep the slot; leave out for a new one.',
          ),
          'exerciseId': JsonSchema.string(),
          'newExercise': _newExerciseSchema,
          'restSeconds': JsonSchema.integer(),
          'circuitGroup': JsonSchema.integer(
            description: 'Adjacent exercises with the same number alternate.',
          ),
          'sets': JsonSchema.array(items: _setSchema),
          'alternatives': JsonSchema.array(
            description:
                'Exercises the user may swap in. Leave out to keep the '
                "slot's alternatives as they are.",
            items: JsonSchema.object(
              properties: {
                'alternativeId': JsonSchema.string(),
                'exerciseId': JsonSchema.string(),
                'newExercise': _newExerciseSchema,
                'sets': JsonSchema.array(
                  description:
                      "Leave empty to use the slot's sets, which fit only an "
                      'exercise of the same kind.',
                  items: _setSchema,
                ),
              },
            ),
          ),
        },
      ),
    ),
  },
  required: ['name', 'exercises'],
);

/// Reads what the save depends on, builds the whole document and commits it
/// with the exercises it adds, refusing at the first rule the draft breaks.
class _RoutineSave {
  _RoutineSave(this._scope, {required this.now, required this.newId});

  final UserScope _scope;
  final DateTime Function() now;
  final String Function() newId;

  Future<RoutineTemplateDto> save(_RoutineDraft draft) async {
    final stored = await _storedRoutineFor(draft);
    final library = _Library(
      await _scope.storedExercises(),
      newId: newId,
      createdAtMs: _wholeSecondsNow(),
    );
    final routine = _RoutineBuilder(
      draft,
      stored == null ? null : RoutineTemplateDto.fromJson(stored.fields),
      library,
      newId: newId,
      createdAtMs: _wholeSecondsNow(),
    ).build();
    try {
      await _scope.commitRoutine(
        DocumentWrite(routine.toJson(), readAt: stored?.updateTime),
        library.writes,
      );
    } on CommitConflict {
      throw ToolRefusal(
        'The routine changed while it was being saved. Read it again with '
        'get_routine and redo the change.',
      );
    }
    return routine;
  }

  Future<StoredDocument?> _storedRoutineFor(_RoutineDraft draft) async {
    final id = draft.id;
    if (id == null) {
      await _refuseTakenName(draft.name);
      return null;
    }
    final version = draft.version;
    if (version == null) {
      throw ToolRefusal('version is required when id is given.');
    }
    final stored = await _scope.storedRoutine(id);
    if (stored == null) throw ToolRefusal('No routine with that id.');
    final routine = RoutineTemplateDto.fromJson(stored.fields);
    if (routine.deletedAtMs != null) {
      throw ToolRefusal(
        'That routine was deleted. Leave out id to create a new one.',
      );
    }
    if (routine.version != version) {
      throw ToolRefusal(
        'The routine changed since you read it: it is at version '
        '${routine.version}. Read it again with get_routine and redo the '
        'change.',
      );
    }
    return stored;
  }

  Future<void> _refuseTakenName(String name) async {
    for (final routine in await liveRoutines(_scope)) {
      if (routine.name.toLowerCase() == name.toLowerCase()) {
        throw ToolRefusal(
          'A routine named ${routine.name} exists: pass id ${routine.syncId} '
          'to change it.',
        );
      }
    }
  }

  /// The phone stores times in whole seconds, so a time with milliseconds
  /// would come back from it changed and be pushed again.
  int _wholeSecondsNow() => now().millisecondsSinceEpoch ~/ 1000 * 1000;
}

class _RoutineBuilder {
  _RoutineBuilder(
    this._draft,
    this._stored,
    this._library, {
    required this.newId,
    required this.createdAtMs,
  });

  final _RoutineDraft _draft;
  final RoutineTemplateDto? _stored;
  final _Library _library;
  final String Function() newId;
  final int createdAtMs;

  RoutineTemplateDto build() {
    _refuseScatteredCircuits();
    final stored = _stored;
    final storedSlots = {
      for (final e in stored?.exercises ?? const <RoutineExerciseDto>[])
        e.syncId: e,
    };
    final seenSlots = <String>{};
    return RoutineTemplateDto(
      syncId: stored?.syncId ?? newId(),
      name: _draft.name,
      version: (stored?.version ?? 0) + 1,
      createdAtMs: stored?.createdAtMs ?? createdAtMs,
      deletedAtMs: null,
      exercises: [
        for (final (index, slot) in _draft.slots.indexed)
          _slot(slot, index, _keptSlot(slot, storedSlots, seenSlots)),
      ],
    );
  }

  RoutineExerciseDto? _keptSlot(
    _SlotDraft slot,
    Map<String, RoutineExerciseDto> stored,
    Set<String> seen,
  ) {
    final slotId = slot.slotId;
    if (slotId == null) return null;
    final kept = stored[slotId];
    if (kept == null || !seen.add(slotId)) {
      throw ToolRefusal('No slot $slotId in this routine.');
    }
    return kept;
  }

  RoutineExerciseDto _slot(
    _SlotDraft slot,
    int index,
    RoutineExerciseDto? kept,
  ) {
    final exercise = _library.resolve(slot.exercise);
    return RoutineExerciseDto(
      syncId: kept?.syncId ?? newId(),
      exerciseSyncId: exercise.id,
      exerciseName: exercise.name,
      exerciseKind: exercise.kind,
      exerciseParams: exercise.params,
      orderIndex: index,
      restSeconds: slot.restSeconds,
      circuitGroup: slot.circuitGroup,
      plannedSets: _sets(slot.sets, exercise, kept?.plannedSets ?? const []),
      alternatives: _alternatives(slot, exercise, kept),
      muscleSyncIds: exercise.muscleIds,
    );
  }

  List<AlternativeRefDto> _alternatives(
    _SlotDraft slot,
    _Exercise primary,
    RoutineExerciseDto? kept,
  ) {
    final drafts = slot.alternatives;
    final alternatives = drafts == null
        ? _sortedByOrder(kept?.alternatives ?? const [])
        : _replacedAlternatives(drafts, primary, kept);
    _refuseBadAlternatives(alternatives, primary);
    return alternatives;
  }

  List<AlternativeRefDto> _replacedAlternatives(
    List<_AlternativeDraft> drafts,
    _Exercise primary,
    RoutineExerciseDto? kept,
  ) {
    final stored = {
      for (final a in kept?.alternatives ?? const <AlternativeRefDto>[])
        a.syncId: a,
    };
    final seen = <String>{};
    return [
      for (final (index, draft) in drafts.indexed)
        _alternative(draft, index, _keptAlternative(draft, stored, seen)),
    ];
  }

  AlternativeRefDto? _keptAlternative(
    _AlternativeDraft draft,
    Map<String, AlternativeRefDto> stored,
    Set<String> seen,
  ) {
    final id = draft.alternativeId;
    if (id == null) return null;
    final kept = stored[id];
    if (kept == null || !seen.add(id)) {
      throw ToolRefusal('No alternative $id in this slot.');
    }
    return kept;
  }

  AlternativeRefDto _alternative(
    _AlternativeDraft draft,
    int index,
    AlternativeRefDto? kept,
  ) {
    final exercise = _library.resolve(draft.exercise);
    return AlternativeRefDto(
      syncId: kept?.syncId ?? newId(),
      exerciseSyncId: exercise.id,
      exerciseName: exercise.name,
      exerciseKind: exercise.kind,
      exerciseParams: exercise.params,
      orderIndex: index,
      plannedSets: _sets(draft.sets, exercise, kept?.plannedSets ?? const []),
    );
  }

  void _refuseBadAlternatives(
    List<AlternativeRefDto> alternatives,
    _Exercise primary,
  ) {
    final seen = {primary.id};
    for (final a in alternatives) {
      if (!seen.add(a.exerciseSyncId)) {
        throw ToolRefusal(
          "An alternative cannot be the slot's own exercise or repeat another "
          'alternative.',
        );
      }
      if (a.exerciseKind != primary.kind && a.plannedSets.isEmpty) {
        throw ToolRefusal(
          'The alternative ${a.exerciseName} is of another kind than '
          '${primary.name}, so it needs sets of its own.',
        );
      }
    }
  }

  /// A kept set keeps its id by position, so the watch's history of the
  /// first set stays with the first set.
  List<PlannedSetDto> _sets(
    List<_SetDraft> drafts,
    _Exercise exercise,
    List<PlannedSetDto> kept,
  ) {
    final keptIds = [
      for (final s in [...kept]..sort((a, b) => a.setIndex - b.setIndex))
        s.syncId,
    ];
    return [
      for (final (index, set) in drafts.indexed)
        set.toDto(
          exercise,
          syncId: index < keptIds.length ? keptIds[index] : newId(),
          setIndex: index,
        ),
    ];
  }

  void _refuseScatteredCircuits() {
    final positions = <int, List<int>>{};
    for (final (index, slot) in _draft.slots.indexed) {
      final group = slot.circuitGroup;
      if (group != null) (positions[group] ??= []).add(index);
    }
    for (final MapEntry(key: group, value: at) in positions.entries) {
      final adjacent = at.last - at.first == at.length - 1;
      if (at.length < 2 || !adjacent) {
        throw ToolRefusal(
          'The exercises of circuit $group must be next to each other, and '
          'at least two.',
        );
      }
    }
  }

  List<AlternativeRefDto> _sortedByOrder(List<AlternativeRefDto> list) =>
      [...list]..sort((a, b) => a.orderIndex - b.orderIndex);
}

/// What a routine slot copies from a library exercise.
class _Exercise {
  _Exercise({
    required this.id,
    required this.name,
    required this.kind,
    required this.params,
    required this.muscleIds,
  });

  factory _Exercise.of(ExerciseDto dto) => _Exercise(
    id: dto.syncId,
    name: dto.name,
    kind: dto.kind,
    params: dto.params,
    muscleIds: knownMuscleIds(dto.muscleSyncIds),
  );

  final String id;
  final String name;
  final String kind;
  final List<ParamEntry> params;
  final List<String> muscleIds;
}

/// The user's exercises, and the ones this save adds or revives.
class _Library {
  _Library(
    List<StoredDocument> stored, {
    required this.newId,
    required this.createdAtMs,
  }) {
    for (final document in stored) {
      final dto = ExerciseDto.fromJson(document.fields);
      if (dto.deletedAtMs == null) {
        _live[dto.syncId] = dto;
      } else {
        _tombstones.putIfAbsent(dto.name, () => (dto, document.updateTime));
      }
    }
  }

  final String Function() newId;
  final int createdAtMs;
  final _live = <String, ExerciseDto>{};
  final _tombstones = <String, (ExerciseDto, String)>{};
  final _added = <String, (_Exercise, DocumentWrite)>{};

  List<DocumentWrite> get writes => [for (final (_, w) in _added.values) w];

  _Exercise resolve(_ExerciseRef ref) => switch (ref) {
    _ExistingExercise() => _existing(ref),
    _NewExercise() => _new(ref),
  };

  _Exercise _existing(_ExistingExercise ref) {
    final dto = _live[ref.exerciseId];
    if (dto == null) {
      throw ToolRefusal(
        'No exercise with id ${ref.exerciseId}. Use find_exercises, or pass '
        'newExercise.',
      );
    }
    final renamed = ref.name != null && ref.name != dto.name;
    final rekinded = ref.kind != null && ref.kind != dto.kind;
    if (renamed || rekinded) {
      throw ToolRefusal(
        'save_routine cannot rename an exercise or change its kind.',
      );
    }
    return _Exercise.of(dto);
  }

  _Exercise _new(_NewExercise ref) {
    final key = ref.name.toLowerCase();
    final added = _added[key];
    if (added != null) return added.$1;
    for (final live in _live.values) {
      if (live.name.toLowerCase() == key) {
        throw ToolRefusal(
          'An exercise named ${live.name} exists: use exerciseId '
          '${live.syncId}.',
        );
      }
    }
    final (dto, readAt) = switch (_tombstones[ref.name]) {
      (final tombstone, final readAt) => (_revived(tombstone, ref), readAt),
      null => (_created(ref), null),
    };
    final exercise = _Exercise.of(dto);
    _added[key] = (exercise, DocumentWrite(dto.toJson(), readAt: readAt));
    return exercise;
  }

  ExerciseDto _revived(ExerciseDto tombstone, _NewExercise ref) => ExerciseDto(
    syncId: tombstone.syncId,
    name: tombstone.name,
    kind: ref.kind,
    params: tombstone.params,
    version: tombstone.version + 1,
    createdAtMs: tombstone.createdAtMs,
    muscleSyncIds: knownMuscleIds(ref.muscleIds),
    deletedAtMs: null,
  );

  ExerciseDto _created(_NewExercise ref) => ExerciseDto(
    syncId: newId(),
    name: ref.name,
    kind: ref.kind,
    version: 1,
    createdAtMs: createdAtMs,
    muscleSyncIds: knownMuscleIds(ref.muscleIds),
    deletedAtMs: null,
  );
}

const _maxSlots = 50;
const _maxSets = 20;
const _maxAlternatives = 10;
const _defaultRestSeconds = 90;
final _idPattern = RegExp(r'^[A-Za-z0-9_:-]{1,64}$');

class _RoutineDraft {
  _RoutineDraft({
    required this.id,
    required this.version,
    required this.name,
    required this.slots,
  });

  factory _RoutineDraft.parse(Object? json) {
    final routine = _object(json, 'routine');
    final slots = _list(routine['exercises'], 'exercises') ?? const [];
    if (slots.length > _maxSlots) {
      throw ToolRefusal('A routine holds at most $_maxSlots exercises.');
    }
    return _RoutineDraft(
      id: _id(routine['id'], 'id'),
      version: _wholeNumber(routine['version'], 'version'),
      name: _name(routine['name']),
      slots: [for (final s in slots) _SlotDraft.parse(s)],
    );
  }

  final String? id;
  final int? version;
  final String name;
  final List<_SlotDraft> slots;
}

class _SlotDraft {
  _SlotDraft({
    required this.slotId,
    required this.exercise,
    required this.restSeconds,
    required this.circuitGroup,
    required this.sets,
    required this.alternatives,
  });

  factory _SlotDraft.parse(Object? json) {
    final slot = _object(json, 'exercise');
    final alternatives = _list(slot['alternatives'], 'alternatives');
    if (alternatives != null && alternatives.length > _maxAlternatives) {
      throw ToolRefusal(
        'A slot holds at most $_maxAlternatives alternatives.',
      );
    }
    return _SlotDraft(
      slotId: _id(slot['slotId'], 'slotId'),
      exercise: _ExerciseRef.parse(slot),
      restSeconds:
          _inRange(slot['restSeconds'], 'restSeconds', 0, 3600) ??
          _defaultRestSeconds,
      circuitGroup: _wholeNumber(slot['circuitGroup'], 'circuitGroup'),
      sets: _SetDraft.parseAll(slot['sets']),
      alternatives: alternatives == null
          ? null
          : [for (final a in alternatives) _AlternativeDraft.parse(a)],
    );
  }

  final String? slotId;
  final _ExerciseRef exercise;
  final int restSeconds;
  final int? circuitGroup;
  final List<_SetDraft> sets;
  final List<_AlternativeDraft>? alternatives;
}

class _AlternativeDraft {
  _AlternativeDraft({
    required this.alternativeId,
    required this.exercise,
    required this.sets,
  });

  factory _AlternativeDraft.parse(Object? json) {
    final alternative = _object(json, 'alternative');
    return _AlternativeDraft(
      alternativeId: _id(alternative['alternativeId'], 'alternativeId'),
      exercise: _ExerciseRef.parse(alternative),
      sets: _SetDraft.parseAll(alternative['sets']),
    );
  }

  final String? alternativeId;
  final _ExerciseRef exercise;
  final List<_SetDraft> sets;
}

sealed class _ExerciseRef {
  static _ExerciseRef parse(Map<String, Object?> json) {
    final exerciseId = _id(json['exerciseId'], 'exerciseId');
    final added = json['newExercise'];
    if ((exerciseId == null) == (added == null)) {
      throw ToolRefusal(
        'Each exercise names either exerciseId or newExercise.',
      );
    }
    if (exerciseId != null) {
      return _ExistingExercise(
        exerciseId,
        name: _optionalString(json['name'], 'name'),
        kind: _optionalString(json['kind'], 'kind'),
      );
    }
    final fresh = _object(added, 'newExercise');
    final muscles = _list(fresh['muscles'], 'muscles') ?? const [];
    return _NewExercise(
      name: _name(fresh['name']),
      kind: _kind(fresh['kind']),
      muscleIds: [for (final m in muscles) _muscleId(m)],
    );
  }
}

/// [name] and [kind] are what get_routine showed; they must still be true.
class _ExistingExercise extends _ExerciseRef {
  _ExistingExercise(this.exerciseId, {this.name, this.kind});

  final String exerciseId;
  final String? name;
  final String? kind;
}

class _NewExercise extends _ExerciseRef {
  _NewExercise({
    required this.name,
    required this.kind,
    required this.muscleIds,
  });

  final String name;
  final String kind;
  final List<String> muscleIds;
}

class _SetDraft {
  _SetDraft({
    required this.reps,
    required this.weightKg,
    required this.seconds,
    required this.parameters,
  });

  static List<_SetDraft> parseAll(Object? json) {
    final sets = _list(json, 'sets') ?? const [];
    if (sets.length > _maxSets) {
      throw ToolRefusal('An exercise holds at most $_maxSets sets.');
    }
    return [for (final s in sets) _SetDraft.parse(s)];
  }

  factory _SetDraft.parse(Object? json) {
    final set = _object(json, 'set');
    final parameters = set['parameters'] == null
        ? const <String, Object?>{}
        : _object(set['parameters'], 'parameters');
    return _SetDraft(
      reps: _inRange(set['reps'], 'reps', 1, 1000),
      weightKg: _weight(set['weightKg']),
      seconds: _inRange(set['seconds'], 'seconds', 1, 86400),
      parameters: {
        for (final MapEntry(:key, :value) in parameters.entries)
          key: _parameterValue(key, value),
      },
    );
  }

  final int? reps;
  final double? weightKg;
  final int? seconds;
  final Map<String, double> parameters;

  PlannedSetDto toDto(
    _Exercise exercise, {
    required String syncId,
    required int setIndex,
  }) {
    final timed = exercise.kind == exerciseKindTime;
    if (timed && (seconds == null || reps != null)) {
      throw ToolRefusal(
        '${exercise.name} is timed: each set needs seconds and no reps.',
      );
    }
    if (!timed && (reps == null || seconds != null)) {
      throw ToolRefusal(
        '${exercise.name} counts reps: each set needs reps and no seconds.',
      );
    }
    return PlannedSetDto(
      syncId: syncId,
      setIndex: setIndex,
      targetReps: reps,
      targetWeightKg: weightKg,
      targetSeconds: seconds,
      targetParams: _parameterIds(exercise),
    );
  }

  ParamValues? _parameterIds(_Exercise exercise) {
    final byName = {for (final p in exercise.params.custom) p.name: p.id};
    final values = <String, double>{};
    for (final MapEntry(:key, :value) in parameters.entries) {
      final id = byName[key];
      if (id == null) {
        throw ToolRefusal('${exercise.name} has no parameter $key.');
      }
      values[id] = value;
    }
    return values.isEmpty ? null : values;
  }
}

Map<String, Object?> _object(Object? json, String field) {
  if (json is Map) return json.cast<String, Object?>();
  throw ToolRefusal('$field must be an object.');
}

List<Object?>? _list(Object? json, String field) {
  if (json == null) return null;
  if (json is List) return json.cast<Object?>();
  throw ToolRefusal('$field must be a list.');
}

String? _optionalString(Object? json, String field) {
  if (json == null || json is String) return json as String?;
  throw ToolRefusal('$field must be a string.');
}

String? _id(Object? json, String field) {
  final id = _optionalString(json, field);
  if (id == null || _idPattern.hasMatch(id)) return id;
  throw ToolRefusal(
    '$field must be 1 to 64 letters, digits, _, : or -, as the read gave it.',
  );
}

String _name(Object? json) {
  final name = _optionalString(json, 'name')?.trim() ?? '';
  if (name.isEmpty || name.length > 100) {
    throw ToolRefusal('A name must be 1 to 100 characters.');
  }
  return name;
}

String _kind(Object? json) {
  if (json == exerciseKindReps || json == exerciseKindTime) {
    return json! as String;
  }
  throw ToolRefusal('kind must be $exerciseKindReps or $exerciseKindTime.');
}

String _muscleId(Object? json) {
  final id = json is String ? muscleIdNamed(json) : null;
  if (id != null) return id;
  throw ToolRefusal(
    'Unknown muscle $json. Use one of: ${muscleSeeds.join(', ')}.',
  );
}

int? _wholeNumber(Object? json, String field) {
  if (json == null) return null;
  if (json is num && json == json.truncateToDouble()) return json.toInt();
  throw ToolRefusal('$field must be a whole number.');
}

int? _inRange(Object? json, String field, int min, int max) {
  final value = json is num && json == json.truncateToDouble()
      ? json.toInt()
      : null;
  if (json == null) return null;
  if (value == null || value < min || value > max) {
    throw ToolRefusal('$field must be a whole number from $min to $max.');
  }
  return value;
}

double? _weight(Object? json) {
  if (json == null) return null;
  if (json is num && json >= 0 && json <= 1000) return json.toDouble();
  throw ToolRefusal('weightKg must be from 0 to 1000.');
}

double _parameterValue(String name, Object? json) {
  if (json is num && json.isFinite) return json.toDouble();
  throw ToolRefusal('The parameter $name must be a number.');
}
