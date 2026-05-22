import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:zenflow_ai/features/workout/providers/workout_session_provider.dart';
import 'package:zenflow_ai/features/dashboard/providers/dashboard_stats_provider.dart';

// ── Profile Model ─────────────────────────────────────────────────────────────

class UserProfile {
  final String userId;
  final String? name;
  final String? email;
  final double? weightKg;
  final double? heightCm;
  final int? ageYears;
  final String? fitnessGoal;
  final List<String> healthConditions;
  final int dailyMinutesAvailable;

  const UserProfile({
    required this.userId,
    this.name,
    this.email,
    this.weightKg,
    this.heightCm,
    this.ageYears,
    this.fitnessGoal,
    this.healthConditions = const [],
    this.dailyMinutesAvailable = 30,
  });

  factory UserProfile.fromMap(String userId, Map<String, dynamic> m) {
    final rawConditions = m['health_conditions'];
    List<String> conditions = [];

    if (rawConditions is List) {
      conditions = rawConditions.map((e) => e.toString()).toList();
    } else if (rawConditions is String && rawConditions.isNotEmpty) {
      conditions = rawConditions.split(',').map((e) => e.trim()).toList();
    }

    return UserProfile(
      userId: userId,
      name: m['full_name'] as String?,
      email: m['email'] as String?,
      weightKg: (m['weight_kg'] as num?)?.toDouble(),
      heightCm: (m['height_cm'] as num?)?.toDouble(),
      ageYears: m['age'] as int?,
      fitnessGoal: m['fitness_goal'] as String?,
      healthConditions: conditions,
      dailyMinutesAvailable: (m['daily_minutes_available'] as int?) ?? 30,
    );
  }

  UserProfile copyWith({
    String? name,
    double? weightKg,
    double? heightCm,
    int? ageYears,
    String? fitnessGoal,
    List<String>? healthConditions,
    int? dailyMinutesAvailable,
  }) {
    return UserProfile(
      userId: userId,
      name: name ?? this.name,
      email: email,
      weightKg: weightKg ?? this.weightKg,
      heightCm: heightCm ?? this.heightCm,
      ageYears: ageYears ?? this.ageYears,
      fitnessGoal: fitnessGoal ?? this.fitnessGoal,
      healthConditions: healthConditions ?? this.healthConditions,
      dailyMinutesAvailable: dailyMinutesAvailable ?? this.dailyMinutesAvailable,
    );
  }
}

// ── Notifier ──────────────────────────────────────────────────────────────────

class ProfileNotifier extends AsyncNotifier<UserProfile?> {
  @override
  Future<UserProfile?> build() async => _fetchProfile();

  Future<UserProfile?> _fetchProfile() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return null;

    try {
      final data = await Supabase.instance.client
          .from('profiles')
          .select()
          .eq('user_id', user.id) // Correct column is user_id, not id
          .maybeSingle();

      if (data == null) return null;
      return UserProfile.fromMap(user.id, data);
    } catch (e) {
      debugPrint('Error fetching profile: $e');
      rethrow;
    }
  }

  /// Saves weight + health conditions, then triggers split regeneration.
  Future<void> saveAndRegenerate({
    double? weightKg,
    double? heightCm,
    List<String>? healthConditions,
    String? name,
    String? fitnessGoal,
    int? dailyMinutesAvailable,
  }) async {
    final current = state.value;

    state = const AsyncLoading();

    state = await AsyncValue.guard(() async {
      final user = Supabase.instance.client.auth.currentUser!;

      // 1. Build update payload (only include non-null fields)
      final Map<String, dynamic> updates = {};
      if (weightKg != null) updates['weight_kg'] = weightKg;
      if (heightCm != null) updates['height_cm'] = heightCm;
      if (healthConditions != null) {
        updates['health_conditions'] = healthConditions.join(',');
      }
      if (name != null) updates['full_name'] = name;
      if (fitnessGoal != null) updates['fitness_goal'] = fitnessGoal;
      if (dailyMinutesAvailable != null) {
        updates['daily_minutes_available'] = dailyMinutesAvailable;
      }

      if (updates.isNotEmpty) {
        updates['user_id'] = user.id;
        await Supabase.instance.client
            .from('profiles')
            .upsert(updates, onConflict: 'user_id');
      }

      // 2. Trigger Edge Function to re-generate the weekly split
      try {
        await Supabase.instance.client.functions.invoke(
          'generate_workout',
          body: {'user_id': user.id},
        ).timeout(const Duration(seconds: 15));
      } catch (e) {
        debugPrint('Edge function generate_workout failed: $e');
      }

      // Invalidate related providers so Dashboard updates
      ref.invalidate(workoutSessionProvider);
      ref.invalidate(dashboardStatsProvider);

      // 3. Return updated profile
      return current?.copyWith(
            name: name,
            weightKg: weightKg,
            heightCm: heightCm,
            fitnessGoal: fitnessGoal,
            healthConditions: healthConditions,
            dailyMinutesAvailable: dailyMinutesAvailable,
          ) ??
          UserProfile(
            userId: user.id,
            name: name,
            email: user.email,
            weightKg: weightKg,
            heightCm: heightCm,
            fitnessGoal: fitnessGoal,
            healthConditions: healthConditions ?? const [],
            dailyMinutesAvailable: dailyMinutesAvailable ?? 30,
          );
    });
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetchProfile);
  }
}

final profileProvider =
    AsyncNotifierProvider<ProfileNotifier, UserProfile?>(ProfileNotifier.new);
