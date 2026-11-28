# 2. The MCP server saves whole routines under a version check

- **Status:** accepted, 2026-11-28
- **Applies to:** `save_routine` in the remote MCP server (D6)
- **Supersedes:** in ADR 0001, the sentence that the code keeps every write
  inside the three sign-in collections

## Context

An assistant connected to GymTracker should be able to build or change a
routine for the user. The phone, the watch and the web already sync routines
through Firestore with version last-writer-wins: the higher `version` wins, and
the phone copies a routine's exercise name, kind and muscles back onto the
library exercise. A write from the server enters that arbitration like any
other device, so it can overwrite an edit the user made on the phone after the
assistant read the routine, or rename a library exercise with a name the
assistant made up.

## Decision

- **A save replaces the whole routine.** The input is the routine in the shape
  `get_routine` returns, sent back changed. There are no patch operations.
- **The read's version is the check.** A replace refuses unless the stored
  version is the draft's version, and writes that version plus 1. One
  `documents.commit` carries the routine and any new exercises, with
  `exists: false` on a create and the read's `updateTime` on a replace, so a
  write landing between the read and the commit refuses too.
- **Exercises are named, never guessed.** A slot names a live exercise by id or
  creates one explicitly. The routine copies name, kind, parameters and muscles
  from the exercise document, never from the draft.
- **One grant covers reading and writing.** `save_routine` is annotated as
  destructive, so the client confirms each call. A grant can save only when the
  consent page showed the sentence that says so; one made before keeps reading
  and must connect again to save.
- **Nothing is deleted.** No tool deletes a routine or an exercise, and no tool
  writes a workout.

The runtime account now writes under `users/{uid}`: the routine and the new
exercises of a save, and nothing else.

## Consequences

The assistant must read before it changes a routine, and read again after any
refusal; a refusal is a sentence telling it so. An edit made on the phone after
the read is never overwritten, at the cost of the assistant redoing its change.

Two edits at the same version, one from the phone and one saved through the
server, still resolve by arrival order, as between the web and the phone today.
Firestore has no unique name, so an exercise created elsewhere during a save can
leave two exercises of one name, the same gap the web has.

A connection made before this release has to be removed and made again in the
assistant before it can save.

## Alternatives considered

**Patch operations** (add a slot, change a set). Smaller drafts, but each
operation needs its own conflict rule, and a version check on the whole routine
is what the sync already understands.

**A separate write scope or consent option.** The client already confirms each
write, and a second switch on the consent page adds a choice the user cannot
judge before trying the connector.

**Matching exercises by name.** Convenient for the assistant, but a near-miss
creates a twin or attaches the wrong exercise, and nothing in the answer would
show which.
