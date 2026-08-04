import 'package:flutter/material.dart';

import 'watch_pick_routine_page.dart';

class WatchApp extends StatelessWidget {
  const WatchApp({super.key, this.ambient = false});

  final bool ambient;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GymTracker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: ambient ? const _AmbientFace() : const WatchPickRoutinePage(),
    );
  }
}

class _AmbientFace extends StatelessWidget {
  const _AmbientFace();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: Text('GymTracker', style: TextStyle(color: Colors.white70)),
        ),
      ),
    );
  }
}
