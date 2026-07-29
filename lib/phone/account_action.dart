import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../sync/auth_service.dart';

/// Account entry point for the top-level section headers (Routines / Exercises
/// / Workouts), narrow app bar and wide list pane alike. Its own [Consumer] so
/// that auth-state changes rebuild only this icon, not the whole list;
/// `.select` further narrows the rebuild to the signed-in/out transition
/// (ignoring token refreshes). Renders nothing when the backend isn't compiled
/// in, keeping plain phone/watch builds free of auth UI.
class AccountAction extends ConsumerWidget {
  const AccountAction({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(authBackendEnabledProvider)) return const SizedBox.shrink();
    final signedIn = ref.watch(
      authStateProvider.select((v) => v.valueOrNull != null),
    );
    return IconButton(
      tooltip: 'Account',
      icon: Icon(
        signedIn ? Icons.account_circle : Icons.account_circle_outlined,
      ),
      onPressed: () => context.push('/account'),
    );
  }
}
