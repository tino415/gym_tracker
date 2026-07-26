/// Shared responsive width breakpoints for the phone/web shell.
///
/// Kept in one place so the adaptive shell and the routines master-detail
/// layout agree on where "compact" ends and where there's room for a side
/// pane. All are measured against `MediaQuery.sizeOf(context).width`.
library;

/// Below this we're "compact" (phone) → bottom [NavigationBar]; at or above it
/// there's room for a side [NavigationRail]. Material's compact/medium boundary.
const double railBreakpoint = 640.0;

/// At or above this width the routines list and editor are shown side by side
/// (master-detail) instead of full-screen pushes. Set above [railBreakpoint] so
/// both panes have room within the app's centered max-width column.
const double masterDetailBreakpoint = 900.0;

/// At or above this width the Routines editor shows a third column — the
/// per-exercise set editor — alongside the list and routine editor. Below it (but
/// still >= [masterDetailBreakpoint]) selecting an exercise swaps the detail pane
/// to the set editor with a back affordance (2-pane).
const double threePaneBreakpoint = 1240.0;

/// Centered content max-width for the 2-pane sections (Exercises / Workouts) and
/// the app's tinted column. Keeps rows from stretching edge to edge.
const double contentMaxWidth = 1100.0;

/// The Routines wide view needs room for up to three columns, so the app's
/// centered column is allowed to grow to this before the tinted margins begin.
const double routinesWideMaxWidth = 1500.0;
