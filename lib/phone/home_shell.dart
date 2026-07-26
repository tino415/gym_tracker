import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'breakpoints.dart';

/// App shell around the three top-level branches (Routines / Exercises /
/// History). Adaptive navigation: a bottom [NavigationBar] on phone-width
/// viewports, a side [NavigationRail] on wide (tablet/desktop/web) ones so the
/// app is usable as a desktop routine editor.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const _destinations =
      <({IconData icon, IconData selected, String label})>[
    (icon: Icons.fitness_center_outlined, selected: Icons.fitness_center, label: 'Routines'),
    (icon: Icons.list_alt_outlined, selected: Icons.list_alt, label: 'Exercises'),
    (icon: Icons.history_outlined, selected: Icons.history, label: 'Workouts'),
  ];

  void _goBranch(int i) => navigationShell.goBranch(
        i,
        // Tapping the active destination pops that branch to its root.
        initialLocation: i == navigationShell.currentIndex,
      );

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= railBreakpoint;

    if (!wide) {
      return Scaffold(
        body: navigationShell,
        bottomNavigationBar: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: _goBranch,
          destinations: [
            for (final d in _destinations)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selected),
                label: d.label,
              ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: _goBranch,
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (final d in _destinations)
                NavigationRailDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selected),
                  label: Text(d.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: navigationShell),
        ],
      ),
    );
  }
}
