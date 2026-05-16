import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wear_plus/wear_plus.dart';

void main() {
  runApp(const ProviderScope(child: GymTrackerApp()));
}

class GymTrackerApp extends StatelessWidget {
  const GymTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gym Tracker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: defaultTargetPlatform == TargetPlatform.android
          ? const _WearOrPhoneShell()
          : const PhoneHome(),
    );
  }
}

class _WearOrPhoneShell extends StatelessWidget {
  const _WearOrPhoneShell();

  @override
  Widget build(BuildContext context) {
    return WatchShape(
      builder: (context, shape, child) {
        if (shape == WearShape.round || shape == WearShape.square) {
          return AmbientMode(
            builder: (context, mode, child) => WatchHome(ambient: mode == WearMode.ambient),
          );
        }
        return const PhoneHome();
      },
    );
  }
}

final _setsProvider = StateProvider<int>((ref) => 0);

class PhoneHome extends ConsumerWidget {
  const PhoneHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sets = ref.watch(_setsProvider);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Gym Tracker'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Sets completed:'),
            Text('$sets', style: Theme.of(context).textTheme.displayMedium),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => ref.read(_setsProvider.notifier).state++,
        tooltip: 'Log set',
        child: const Icon(Icons.add),
      ),
    );
  }
}

class WatchHome extends ConsumerWidget {
  const WatchHome({super.key, required this.ambient});
  final bool ambient;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sets = ref.watch(_setsProvider);
    return Scaffold(
      backgroundColor: ambient ? Colors.black : Theme.of(context).colorScheme.surface,
      body: Center(
        child: GestureDetector(
          onTap: ambient ? null : () => ref.read(_setsProvider.notifier).state++,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '$sets',
                style: TextStyle(
                  fontSize: 56,
                  color: ambient ? Colors.white70 : Theme.of(context).colorScheme.onSurface,
                ),
              ),
              if (!ambient) const Text('tap to log a set'),
            ],
          ),
        ),
      ),
    );
  }
}
