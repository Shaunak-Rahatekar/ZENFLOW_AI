import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Expose a refreshable version so WorkoutSessionNotifier can invalidate it.
// The provider is a FutureProvider — calling ref.invalidate(dashboardStatsProvider)
// from any widget or notifier will trigger a fresh fetch.

/// Provides dashboard statistics from Supabase.
/// On any fetch error (e.g. PGRST205 table-not-found, network) the provider
/// returns [DashboardStats.syncing] so the UI can show a soft placeholder
/// rather than an error card.
final dashboardStatsProvider = FutureProvider<DashboardStats>((ref) async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) return DashboardStats.empty();

  try {
    final logsResponse = await Supabase.instance.client
        .from('workout_logs')
        .select('workout_date, duration_minutes, calories_burned')
        .eq('user_id', user.id)
        .not('completed_at', 'is', null)
        .order('workout_date', ascending: false);

    final logs = List<Map<String, dynamic>>.from(logsResponse as List);

    // Total workouts
    final totalWorkouts = logs.length;

    // Today's calories
    final today = DateTime.now().toIso8601String().split('T')[0];
    final todayLog = logs.where((l) => l['workout_date'] == today);
    final todayCalories = todayLog.fold<int>(
      0,
      (sum, l) => sum + ((l['calories_burned'] as int?) ?? 0),
    );

    // Calculate current streak (consecutive days with a completed workout)
    int streak = 0;
    final uniqueDates = logs
        .map((l) => l['workout_date'] as String)
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));

    DateTime checkDate = DateTime.now();
    for (final dateStr in uniqueDates) {
      final logDate = DateTime.parse(dateStr);
      final diff = checkDate.difference(logDate).inDays;
      if (diff == 0 || diff == 1) {
        streak++;
        checkDate = logDate;
      } else {
        break;
      }
    }

    return DashboardStats(
      totalWorkouts: totalWorkouts,
      currentStreak: streak,
      todayCalories: todayCalories,
    );
  } catch (e) {
    // Table may not exist yet (PGRST205) or network is unavailable.
    // Return a syncing placeholder so the UI degrades gracefully.
    return DashboardStats.syncing();
  }
});

class DashboardStats {
  final int totalWorkouts;
  final int currentStreak;
  final int todayCalories;
  /// True when data could not be fetched (table missing / offline).
  final bool isSyncing;

  const DashboardStats({
    required this.totalWorkouts,
    required this.currentStreak,
    required this.todayCalories,
    this.isSyncing = false,
  });

  factory DashboardStats.empty() => const DashboardStats(
        totalWorkouts: 0,
        currentStreak: 0,
        todayCalories: 0,
      );

  factory DashboardStats.syncing() => const DashboardStats(
        totalWorkouts: 0,
        currentStreak: 0,
        todayCalories: 0,
        isSyncing: true,
      );
}
