import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ── Filter Enum ───────────────────────────────────────────────────────────────

enum ReportsFilter { today, thisWeek, overall }

// ── Data Model ────────────────────────────────────────────────────────────────

class WorkoutLogEntry {
  final String date;        // 'YYYY-MM-DD'
  final int workouts;
  final int calories;

  const WorkoutLogEntry({
    required this.date,
    required this.workouts,
    required this.calories,
  });
}

class ReportsData {
  final List<WorkoutLogEntry> entries;
  final int totalWorkouts;
  final int totalCalories;
  final int totalMinutes;

  const ReportsData({
    required this.entries,
    required this.totalWorkouts,
    required this.totalCalories,
    required this.totalMinutes,
  });

  factory ReportsData.empty() => const ReportsData(
        entries: [],
        totalWorkouts: 0,
        totalCalories: 0,
        totalMinutes: 0,
      );

  bool get isEmpty => entries.isEmpty;
}

// ── Provider ──────────────────────────────────────────────────────────────────

/// Family provider — fetches report data filtered by [ReportsFilter]
final reportsProvider =
    FutureProvider.family<ReportsData, ReportsFilter>((ref, filter) async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) return ReportsData.empty();

  final now = DateTime.now();
  DateTime? cutoff;
  if (filter == ReportsFilter.today) {
    cutoff = DateTime(now.year, now.month, now.day);
  } else if (filter == ReportsFilter.thisWeek) {
    cutoff = now.subtract(const Duration(days: 6));
    cutoff = DateTime(cutoff.year, cutoff.month, cutoff.day);
  }

  var query = Supabase.instance.client
      .from('workout_logs')
      .select('workout_date, calories_burned, duration_minutes')
      .eq('user_id', user.id)
      .not('completed_at', 'is', null);

  if (cutoff != null) {
    query = query.gte('workout_date', cutoff.toIso8601String().split('T')[0]);
  }

  final raw = await query.order('workout_date', ascending: true);
  final logs = List<Map<String, dynamic>>.from(raw as List);

  if (logs.isEmpty) return ReportsData.empty();

  // Group by date
  final grouped = <String, WorkoutLogEntry>{};
  for (final log in logs) {
    final date = log['workout_date'] as String;
    final cal = (log['calories_burned'] as int?) ?? 0;
    if (grouped.containsKey(date)) {
      final existing = grouped[date]!;
      grouped[date] = WorkoutLogEntry(
        date: date,
        workouts: existing.workouts + 1,
        calories: existing.calories + cal,
      );
    } else {
      grouped[date] = WorkoutLogEntry(date: date, workouts: 1, calories: cal);
    }
  }

  final entries = grouped.values.toList()
    ..sort((a, b) => a.date.compareTo(b.date));

  return ReportsData(
    entries: entries,
    totalWorkouts: logs.length,
    totalCalories: logs.fold(0, (s, l) => s + ((l['calories_burned'] as int?) ?? 0)),
    totalMinutes: logs.fold(0, (s, l) => s + ((l['duration_minutes'] as int?) ?? 0)),
  );
});
