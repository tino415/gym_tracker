import 'package:flutter/material.dart';

/// Selection API handed to a section's `onAdd` so it can drive the pane after an
/// async add flow (e.g. a "log workout" modal that creates a row then selects
/// it, or an inline "new" that opens a blank draft).
abstract class WideMasterDetailApi {
  /// Show the editor for an existing row.
  void select(String id);

  /// Show a blank editor (create-new). Sections without an inline draft (e.g.
  /// workouts, created via a modal) never call this.
  void newDraft();
}

/// Shared wide-viewport master-detail scaffold: a pinned list pane on the left
/// and an inline editor on the right. Owns the selection state machine
/// (select / new-draft / clear-after-delete) so Routines, Exercises and
/// Workouts stay consistent. Narrow viewports keep their own full-screen,
/// push-navigated pages — this is only built above the breakpoint.
class WideMasterDetail extends StatefulWidget {
  const WideMasterDetail({
    super.key,
    required this.title,
    required this.addTooltip,
    required this.onAdd,
    required this.listBuilder,
    required this.detailBuilder,
    required this.placeholder,
    this.listWidth = 320,
  });

  final String title;
  final String addTooltip;

  /// Header "+" action. Async so it can run a modal before selecting.
  final Future<void> Function(WideMasterDetailApi api) onAdd;

  /// Builds the list body, wired to select rows and highlight [selectedId].
  final Widget Function(void Function(String id) onSelect, String? selectedId)
      listBuilder;

  /// Builds the editor for the current selection. [selectedId] is null for a
  /// draft ([isDraft] true). [onDeleted] clears back to the placeholder;
  /// [onCreated] records a freshly persisted id (for highlight) without
  /// re-creating the editor.
  final Widget Function(
    String? selectedId,
    bool isDraft,
    VoidCallback onDeleted,
    ValueChanged<String> onCreated,
  ) detailBuilder;

  /// Shown in the detail pane before anything is selected.
  final Widget placeholder;

  final double listWidth;

  @override
  State<WideMasterDetail> createState() => _WideMasterDetailState();
}

class _WideMasterDetailState extends State<WideMasterDetail>
    implements WideMasterDetailApi {
  String? _selectedId;
  bool _isDraft = false;

  /// Re-bootstrap key for the embedded editor. Bumped only on user-initiated
  /// switches — never on [_onCreated] — so persisting a draft in place doesn't
  /// tear the editor's state down mid-flow.
  int _epoch = 0;

  @override
  void select(String id) => setState(() {
        _selectedId = id;
        _isDraft = false;
        _epoch++;
      });

  @override
  void newDraft() => setState(() {
        _selectedId = null;
        _isDraft = true;
        _epoch++;
      });

  void _clear() => setState(() {
        _selectedId = null;
        _isDraft = false;
        _epoch++;
      });

  void _onCreated(String id) => setState(() {
        _selectedId = id;
        _isDraft = false;
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      // Fill the space left of the rail: the list pane hugs the rail and the
      // detail expands to the right edge. (Centering a capped block here left a
      // gap between the rail and the list.)
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: widget.listWidth,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.title,
                          style: theme.textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: widget.addTooltip,
                        onPressed: () => widget.onAdd(this),
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: widget.listBuilder(select, _selectedId)),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _detail()),
        ],
      ),
    );
  }

  Widget _detail() {
    if (_selectedId != null || _isDraft) {
      return KeyedSubtree(
        key: ValueKey(_epoch),
        child: widget.detailBuilder(_selectedId, _isDraft, _clear, _onCreated),
      );
    }
    return widget.placeholder;
  }
}

/// Centered "nothing selected yet" placeholder for a detail pane.
class MasterDetailPlaceholder extends StatelessWidget {
  const MasterDetailPlaceholder({
    super.key,
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(label, style: TextStyle(color: theme.colorScheme.outline)),
          ],
        ),
      ),
    );
  }
}
