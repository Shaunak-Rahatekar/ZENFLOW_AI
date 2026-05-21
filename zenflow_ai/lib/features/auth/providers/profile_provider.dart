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
  final int? ageYears;
  final String? fitnessGoal;
  final List<String> healthConditions;

  const UserProfile({
    required this.userId,
    this.name,
    this.email,
    this.weightKg,
    this.ageYears,
    this.fitnessGoal,
    this.healthConditions = const [],
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
      ageYears: m['age'] as int?,
      fitnessGoal: m['fitness_goal'] as String?,
      healthConditions: conditions,
    );
  }

  UserProfile copyWith({
    String? name,
    double? weightKg,
    int? ageYears,
    String? fitnessGoal,
    List<String>? healthConditions,
  }) {
    return UserProfile(
      userId: userId,
      name: name ?? this.name,
      email: email,
      weightKg: weightKg ?? this.weightKg,
      ageYears: ageYears ?? this.ageYears,
      fitnessGoal: fitnessGoal ?? this.fitnessGoal,
      healthConditions: healthConditions ?? this.healthConditions,
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
    List<String>? healthConditions,
    String? name,
    String? fitnessGoal,
  }) async {
    final current = state.value;

    state = const AsyncLoading();

    state = await AsyncValue.guard(() async {
      final user = Supabase.instance.client.auth.currentUser!;

      // 1. Build update payload (only changed fields)
      final Map<String, dynamic> updates = {};
      if (weightKg != null) updates['weight_kg'] = weightKg;
      if (healthConditions != null) {
        updates['health_conditions'] = healthConditions.join(','); // Stored as comma-separated string
      }
      if (name != null) updates['full_name'] = name;
      if (fitnessGoal != null) updates['fitness_goal'] = fitnessGoal;

      if (updates.isNotEmpty) {
        // Use upsert in case the user was created before the trigger existed
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
            fitnessGoal: fitnessGoal,
            healthConditions: healthConditions,
          ) ??
          UserProfile(
            userId: user.id,
            name: name,
            email: user.email,
            weightKg: weightKg,
            fitnessGoal: fitnessGoal,
            healthConditions: healthConditions ?? const [],
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
