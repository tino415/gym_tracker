import 'package:flutter/material.dart';

class WatchWorkoutDonePage extends StatelessWidget {
  const WatchWorkoutDonePage({
    super.key,
    required this.routineName,
    this.avgHeartRate,
    this.maxHeartRate,
  });

  final String routineName;
  final int? avgHeartRate;
  final int? maxHeartRate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasHr = avgHeartRate != null || maxHeartRate != null;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.check_circle_outline,
                size: 48,
                color: scheme.primary,
              ),
              const SizedBox(height: 12),
              const Text(
                'Workout complete',
                style: TextStyle(fontWeight: FontWeight.w500),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                routineName,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (hasHr) ...[
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.favorite,
                      size: 14,
                      color: scheme.error,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _hrLine(avgHeartRate, maxHeartRate),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    Navigator.of(context).popUntil((route) => route.isFirst);
                  },
                  child: const Text('Home'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _hrLine(int? avg, int? max) {
    if (avg != null && max != null) return 'avg $avg · max $max bpm';
    if (avg != null) return 'avg $avg bpm';
    return 'max $max bpm';
  }
}
