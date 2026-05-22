import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:zenflow_ai/features/dashboard/providers/dashboard_stats_provider.dart';
import 'package:zenflow_ai/features/reports/providers/reports_provider.dart';
import 'package:zenflow_ai/features/workout/services/tts_service.dart';

// ── SharedPreferences keys ────────────────────────────────────────────────────
const _kSplitId = 'session_split_id';
const _kAsanaIndex = 'session_asana_index';
const _kElapsedTime = 'session_elapsed_time';
const _kPosesCompleted = 'session_poses_completed';

// ── Session constants ─────────────────────────────────────────────────────────
const int _kDefaultAsanaDuration = 60;
const int _kRestDuration = 15;
const int _kMaxRestExtensions = 3;

// ── MET value for yoga (used for calorie estimation) ─────────────────────────
// MET 2.5 = light yoga. calories = MET * weightKg * hours
const double _kYogaMet = 2.5;

enum WorkoutStatus { idle, loading, preview, active, paused, rest, completed }

class WorkoutSessionState {
  final WorkoutStatus status;
  final String? splitId;
  final int currentAsanaIndex;
  final int elapsedSeconds;
  final int asanaCountdownSeconds;
  final int restSecondsRemaining;
  final int restExtensions;
  final int previewCountdown;       // 3-2-1 before each pose
  final int posesCompleted;         // how many poses finished (not skipped)
  final Map<String, dynamic>? currentAsana;
  final List<dynamic> asanas;
  final String? errorMessage;
  final double userWeightKg;        // for calorie calculation
  final double currentAccuracy;     // 0.0 to 100.0
  final double averageAccuracy;     // 0.0 to 100.0
  final int accuracySamples;

  const WorkoutSessionState({
    this.status = WorkoutStatus.idle,
    this.splitId,
    this.currentAsanaIndex = 0,
    this.elapsedSeconds = 0,
    this.asanaCountdownSeconds = _kDefaultAsanaDuration,
    this.restSecondsRemaining = _kRestDuration,
    this.restExtensions = 0,
    this.previewCountdown = 3,
    this.posesCompleted = 0,
    this.currentAsana,
    this.asanas = const [],
    this.errorMessage,
    this.userWeightKg = 70.0,
    this.currentAccuracy = 0.0,
    this.averageAccuracy = 0.0,
    this.accuracySamples = 0,
  });

  WorkoutSessionState copyWith({
    WorkoutStatus? status,
    String? splitId,
    int? currentAsanaIndex,
    int? elapsedSeconds,
    int? asanaCountdownSeconds,
    int? restSecondsRemaining,
    int? restExtensions,
    int? previewCountdown,
    int? posesCompleted,
    Map<String, dynamic>? currentAsana,
    List<dynamic>? asanas,
    String? errorMessage,
    double? userWeightKg,
    double? currentAccuracy,
    double? averageAccuracy,
    int? accuracySamples,
  }) {
    return WorkoutSessionState(
      status: status ?? this.status,
      splitId: splitId ?? this.splitId,
      currentAsanaIndex: currentAsanaIndex ?? this.currentAsanaIndex,
      elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
      asanaCountdownSeconds: asanaCountdownSeconds ?? this.asanaCountdownSeconds,
      restSecondsRemaining: restSecondsRemaining ?? this.restSecondsRemaining,
      restExtensions: restExtensions ?? this.restExtensions,
      previewCountdown: previewCountdown ?? this.previewCountdown,
      posesCompleted: posesCompleted ?? this.posesCompleted,
      currentAsana: currentAsana ?? this.currentAsana,
      asanas: asanas ?? this.asanas,
      errorMessage: errorMessage,
      userWeightKg: userWeightKg ?? this.userWeightKg,
      currentAccuracy: currentAccuracy ?? this.currentAccuracy,
      averageAccuracy: averageAccuracy ?? this.averageAccuracy,
      accuracySamples: accuracySamples ?? this.accuracySamples,
    );
  }

  int get currentAsanaDuration {
    final dur = currentAsana?['duration_seconds'];
    if (dur is int) return dur;
    if (dur is num) return dur.toInt();
    if (dur is String) return int.tryParse(dur) ?? _kDefaultAsanaDuration;
    return _kDefaultAsanaDuration;
  }

  double get asanaProgress {
    final total = currentAsanaDuration;
    if (total <= 0) return 0.0;
    return (1.0 - (asanaCountdownSeconds / total)).clamp(0.0, 1.0);
  }

  double get restProgress {
    final total = _kRestDuration + (restExtensions * 60);
    if (total <= 0) return 0.0;
    return (restSecondsRemaining / total).clamp(0.0, 1.0);
  }

  bool get canExtendRest => restExtensions < _kMaxRestExtensions;

  Map<String, dynamic>? get nextAsana {
    final nextIdx = currentAsanaIndex + 1;
    if (nextIdx >= asanas.length) return null;
    return asanas[nextIdx] as Map<String, dynamic>?;
  }

  /// Estimated calories burned based on elapsed time and user weight.
  int get estimatedCalories {
    final hours = elapsedSeconds / 3600.0;
    return (_kYogaMet * userWeightKg * hours).round();
  }

  double get completionPercentage {
    if (asanas.isEmpty) return 0.0;
    return (posesCompleted / asanas.length * 100).clamp(0.0, 100.0);
  }
}

class WorkoutSessionNotifier extends AsyncNotifier<WorkoutSessionState> {
  SharedPreferences? _prefs;
  final _secureStorage = const FlutterSecureStorage();

  @override
  Future<WorkoutSessionState> build() async {
    _prefs = await SharedPreferences.getInstance();
    await _syncPendingLogs();

    final sub = Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((r) => r != ConnectivityResult.none)) {
        _syncPendingLogs();
      }
    });
    ref.onDispose(() => sub.cancel());

    return await _rehydrateSession();
  }

  // ── Offline sync ────────────────────────────────────────────────────────────

  Future<void> _syncPendingLogs() async {
    final pendingLogsStr = await _secureStorage.read(key: 'pending_sync_logs');
    if (pendingLogsStr == null || pendingLogsStr.isEmpty) return;

    List<String> pendingLogs = [];
    try {
      pendingLogs = List<String>.from(jsonDecode(pendingLogsStr));
    } catch (_) { return; }
    if (pendingLogs.isEmpty) return;

    final List<String> remainingLogs = [];
    for (final logJson in pendingLogs) {
      try {
        final logMap = jsonDecode(logJson);
        await Supabase.instance.client.from('workout_logs').insert(logMap);
      } catch (_) {
        remainingLogs.add(logJson);
      }
    }
    await _secureStorage.write(
      key: 'pending_sync_logs',
      value: jsonEncode(remainingLogs),
    );
  }

  // ── Session rehydration ─────────────────────────────────────────────────────

  Future<WorkoutSessionState> _rehydrateSession() async {
    final savedSplitId = _prefs?.getString(_kSplitId);
    final savedAsanaIndex = _prefs?.getInt(_kAsanaIndex);
    final savedElapsed = _prefs?.getInt(_kElapsedTime);
    final savedPosesCompleted = _prefs?.getInt(_kPosesCompleted) ?? 0;

    if (savedSplitId != null && savedAsanaIndex != null) {
      // Reload asanas so the session is fully functional on resume
      try {
        final asanas = await _loadAsanasForSplit(savedSplitId, savedAsanaIndex);
        if (asanas.isNotEmpty) {
          final asana = asanas[savedAsanaIndex] as Map<String, dynamic>?;
          return WorkoutSessionState(
            status: WorkoutStatus.paused,
            splitId: savedSplitId,
            currentAsanaIndex: savedAsanaIndex,
            elapsedSeconds: savedElapsed ?? 0,
            posesCompleted: savedPosesCompleted,
            asanas: asanas,
            currentAsana: asana,
            asanaCountdownSeconds: _parseDuration(asana),
          );
        }
      } catch (_) { /* fall through to idle */ }
    }
    return const WorkoutSessionState(status: WorkoutStatus.idle);
  }

  /// Loads today's asana list for a given split from Supabase + local registry.
  Future<List<dynamic>> _loadAsanasForSplit(String splitId, int fromIndex) async {
    final response = await Supabase.instance.client
        .from('weekly_splits')
        .select('start_date, split_data')
        .eq('id', splitId)
        .maybeSingle();
    if (response == null) return [];

    final startDate = DateTime.parse(response['start_date'] as String);
    final dayIndex = DateTime.now().difference(startDate).inDays.clamp(0, 6);
    final splitData = response['split_data'] as List<dynamic>;
    if (dayIndex >= splitData.length) return [];

    final todayIds = splitData[dayIndex] as List<dynamic>? ?? [];
    return await _hydrateAsanas(todayIds.map((e) => e.toString()).toList());
  }

  // ── Public API ──────────────────────────────────────────────────────────────

  /// Fetches today's asanas from Supabase, hydrates from local registry, starts preview.
  Future<void> fetchAndStartWorkout() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      // Load user weight for calorie calculation
      double weightKg = 70.0;
      try {
        final profile = await Supabase.instance.client
            .from('profiles')
            .select('weight_kg')
            .eq('user_id', user.id)
            .maybeSingle();
        weightKg = (profile?['weight_kg'] as num?)?.toDouble() ?? 70.0;
      } catch (_) {}

      final response = await Supabase.instance.client
          .from('weekly_splits')
          .select('id, start_date, split_data')
          .eq('user_id', user.id)
          .order('start_date', ascending: false)
          .limit(1)
          .maybeSingle();

      if (response == null) {
        await Supabase.instance.client.functions.invoke(
          'generate_workout',
          body: {'user_id': user.id},
        );
        return const WorkoutSessionState(status: WorkoutStatus.idle);
      }

      final startDate = DateTime.parse(response['start_date'] as String);
      final dayIndex = DateTime.now().difference(startDate).inDays.clamp(0, 6);
      final splitData = response['split_data'] as List<dynamic>;
      if (dayIndex >= splitData.length) {
        return const WorkoutSessionState(status: WorkoutStatus.idle);
      }

      final todayIds = splitData[dayIndex];
      if (todayIds == null || (todayIds as List).isEmpty) {
        return const WorkoutSessionState(status: WorkoutStatus.idle);
      }

      final asanas = await _hydrateAsanas(
        todayIds.map((e) => e.toString()).toList(),
      );
      if (asanas.isEmpty) {
        return const WorkoutSessionState(status: WorkoutStatus.idle);
      }

      final splitId = response['id'] as String;
      final firstAsana = asanas[0] as Map<String, dynamic>;
      
      final poseName = firstAsana['english_name'] as String? ?? 'Daily Flow';
      TtsService.instance.speakGreeting(poseName);

      // Start with preview state (3-2-1 countdown before first pose)
      return WorkoutSessionState(
        status: WorkoutStatus.preview,
        splitId: splitId,
        currentAsanaIndex: 0,
        elapsedSeconds: 0,
        previewCountdown: 3,
        posesCompleted: 0,
        asanas: asanas,
        currentAsana: firstAsana,
        asanaCountdownSeconds: _parseDuration(firstAsana),
        userWeightKg: weightKg,
      );
    });
  }

  void resume() {
    final current = state.value;
    if (current == null) return;
    if (current.status == WorkoutStatus.paused) {
      // Resume into preview for the current pose
      state = AsyncData(current.copyWith(
        status: WorkoutStatus.preview,
        previewCountdown: 3,
      ));
    } else if (current.status == WorkoutStatus.rest) {
      state = AsyncData(current.copyWith(status: WorkoutStatus.active));
    }
  }

  Future<void> pause() async {
    final current = state.value;
    if (current == null) return;
    if (current.status != WorkoutStatus.active &&
        current.status != WorkoutStatus.preview &&
        current.status != WorkoutStatus.rest) return;

    if (current.splitId != null) {
      await _saveToPrefs(
        splitId: current.splitId!,
        asanaIndex: current.currentAsanaIndex,
        elapsed: current.elapsedSeconds,
        posesCompleted: current.posesCompleted,
      );
    }
    state = AsyncData(current.copyWith(status: WorkoutStatus.paused));
  }

  void rest() {
    final current = state.value;
    if (current == null || current.status != WorkoutStatus.active) return;
    state = AsyncData(current.copyWith(
      status: WorkoutStatus.rest,
      restSecondsRemaining: _kRestDuration,
      posesCompleted: current.posesCompleted + 1,
    ));
  }

  void extendRest() {
    final current = state.value;
    if (current == null || current.status != WorkoutStatus.rest) return;
    if (!current.canExtendRest) return;
    state = AsyncData(current.copyWith(
      restSecondsRemaining: current.restSecondsRemaining + 60,
      restExtensions: current.restExtensions + 1,
    ));
  }

  void nextAsana() {
    final current = state.value;
    if (current == null) return;

    // Guard: if asanas list is empty the session was never properly loaded.
    // Do not complete — just return to idle to avoid a zero-duration log entry.
    if (current.asanas.isEmpty) {
      debugPrint('[Session] nextAsana called with empty asanas list — ignoring');
      return;
    }

    final nextIndex = current.currentAsanaIndex + 1;

    if (nextIndex >= current.asanas.length) {
      _completeSession();
      return;
    }

    final nextAsana = current.asanas[nextIndex] as Map<String, dynamic>?;
    
    if (nextAsana != null) {
      final poseName = nextAsana['english_name'] as String? ?? 'Next Pose';
      final orientation = nextAsana['preferred_orientation'] as String? ?? 'front';
      TtsService.instance.speakNextPose(poseName, orientation);
    }
    
    state = AsyncData(current.copyWith(
      status: WorkoutStatus.preview,
      currentAsanaIndex: nextIndex,
      currentAsana: nextAsana,
      asanaCountdownSeconds: _parseDuration(nextAsana),
      restSecondsRemaining: _kRestDuration,
      restExtensions: 0,
      previewCountdown: 3,
    ));
  }

  // ── Timer ticks (called every second by master timer) ──────────────────────

  void tick() {
    final current = state.value;
    if (current == null) return;
    if (current.status != WorkoutStatus.active &&
        current.status != WorkoutStatus.rest) return;
    state = AsyncData(current.copyWith(
      elapsedSeconds: current.elapsedSeconds + 1,
    ));
  }

  void tickAsana() {
    final current = state.value;
    if (current == null || current.status != WorkoutStatus.active) return;
    // Don't tick if asanas haven't loaded yet
    if (current.asanas.isEmpty || current.currentAsana == null) return;
    final next = current.asanaCountdownSeconds - 1;
    if (next <= 0) {
      rest();
    } else {
      state = AsyncData(current.copyWith(asanaCountdownSeconds: next));
    }
  }

  void tickRest() {
    final current = state.value;
    if (current == null || current.status != WorkoutStatus.rest) return;
    // Don't tick if asanas haven't loaded yet
    if (current.asanas.isEmpty) return;
    final next = current.restSecondsRemaining - 1;
    if (next <= 0) {
      nextAsana();
    } else {
      state = AsyncData(current.copyWith(restSecondsRemaining: next));
    }
  }

  /// Ticks the 3-2-1 preview countdown. When it hits 0, transitions to active.
  void tickPreview() {
    final current = state.value;
    if (current == null || current.status != WorkoutStatus.preview) return;
    final next = current.previewCountdown - 1;
    if (next <= 0) {
      state = AsyncData(current.copyWith(status: WorkoutStatus.active));
    } else {
      state = AsyncData(current.copyWith(previewCountdown: next));
    }
  }

  Future<void> handleAppBackground() async {
    final current = state.value;
    if (current?.status == WorkoutStatus.active ||
        current?.status == WorkoutStatus.rest ||
        current?.status == WorkoutStatus.preview) {
      await pause();
    }
  }

  Future<void> cancelSession() async {
    await _clearPrefs();
    state = const AsyncData(WorkoutSessionState(status: WorkoutStatus.idle));
  }

  // ── Session completion ──────────────────────────────────────────────────────

  Future<void> _completeSession() async {
    final current = state.value;
    await _clearPrefs();

    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null && current?.splitId != null) {
        final now = DateTime.now();
        final startedAt = now.subtract(Duration(seconds: current!.elapsedSeconds));
        final calories = current.estimatedCalories;
        final posesCompleted = current.posesCompleted;
        final totalPoses = current.asanas.length;
        final completionPct = current.completionPercentage;
        final asanaName = current.currentAsana?['english_name'] as String? ?? 'Daily Flow';

        // Fetch goal_type from profile
        String goalType = 'General Fitness';
        try {
          final profile = await Supabase.instance.client
              .from('profiles')
              .select('fitness_goal')
              .eq('user_id', user.id)
              .maybeSingle();
          goalType = profile?['fitness_goal'] as String? ?? 'General Fitness';
        } catch (_) {}

        final logData = {
          'user_id': user.id,
          'split_id': current.splitId,
          'workout_date': now.toIso8601String().split('T')[0],
          'started_at': startedAt.toIso8601String(),
          'completed_at': now.toIso8601String(),
          'duration_minutes': current.elapsedSeconds ~/ 60,
          'calories_burned': calories,
          'posture_score_avg': current.averageAccuracy,
          'performance_data': {
            'workout_id': current.splitId,
            'workout_name': 'Day ${current.currentAsanaIndex + 1} — $asanaName',
            'asana_id': 'Daily Flow',
            'poses_completed': posesCompleted,
            'completion_percentage': completionPct.round(),
            'average_accuracy': current.averageAccuracy.round(),
            'streak_day': 1,
            'goal_type': goalType,
          },
        };

        try {
          debugPrint('[Session] Inserting workout log: duration=${current.elapsedSeconds}s poses=$posesCompleted cal=$calories');
          await Supabase.instance.client.from('workout_logs').insert(logData);
          debugPrint('[Session] Workout log inserted successfully');
        } catch (e) {
          debugPrint('[Session] Insert failed, queuing offline: $e');
          final pendingLogsStr = await _secureStorage.read(key: 'pending_sync_logs');
          List<String> pending = [];
          if (pendingLogsStr != null && pendingLogsStr.isNotEmpty) {
            try { pending = List<String>.from(jsonDecode(pendingLogsStr)); } catch (_) {}
          }
          pending.add(jsonEncode(logData));
          await _secureStorage.write(
            key: 'pending_sync_logs',
            value: jsonEncode(pending),
          );
        }
      }
    } catch (_) { /* silent — don't block completion */ }

    state = AsyncData(current!.copyWith(status: WorkoutStatus.completed));
    TtsService.instance.speakCompletion();

    // Invalidate dashboard and reports providers so they re-fetch immediately.
    // We must NOT call ref.invalidateSelf() here — that would wipe the completed
    // state before the dashboard listener can observe the transition.
    try {
      ref.invalidate(dashboardStatsProvider);
      // Invalidate all filter variants of the family provider
      ref.invalidate(reportsProvider(ReportsFilter.today));
      ref.invalidate(reportsProvider(ReportsFilter.thisWeek));
      ref.invalidate(reportsProvider(ReportsFilter.overall));
    } catch (_) {}
  }  // ← closes _completeSession

  void updateAccuracy(double accuracy) {
    if (state.value == null || state.value!.status != WorkoutStatus.active) return;
    
    final current = state.value!;
    final newSamples = current.accuracySamples + 1;
    // Compute running average
    final newAvg = ((current.averageAccuracy * current.accuracySamples) + accuracy) / newSamples;
    
    state = AsyncData(current.copyWith(
      currentAccuracy: accuracy,
      averageAccuracy: newAvg,
      accuracySamples: newSamples,
    ));
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  Future<List<dynamic>> _hydrateAsanas(List<String> ids) async {
    final registryJson = await rootBundle.loadString('assets/data/asana_registry.json');
    final registryList = jsonDecode(registryJson) as List<dynamic>;
    final registry = <String, Map<String, dynamic>>{
      for (final item in registryList)
        (item as Map<String, dynamic>)['id'] as String: item,
    };

    final result = <Map<String, dynamic>>[];
    for (final id in ids) {
      final asana = registry[id];
      if (asana != null) {
        result.add({
          ...asana,
          'duration_seconds': asana['duration_seconds'] ?? _kDefaultAsanaDuration,
        });
      }
    }
    return result;
  }

  int _parseDuration(Map<String, dynamic>? asana) {
    final dur = asana?['duration_seconds'];
    if (dur is int) return dur;
    if (dur is num) return dur.toInt();
    if (dur is String) return int.tryParse(dur) ?? _kDefaultAsanaDuration;
    return _kDefaultAsanaDuration;
  }

  Future<void> _saveToPrefs({
    required String splitId,
    required int asanaIndex,
    required int elapsed,
    required int posesCompleted,
  }) async {
    await _prefs?.setString(_kSplitId, splitId);
    await _prefs?.setInt(_kAsanaIndex, asanaIndex);
    await _prefs?.setInt(_kElapsedTime, elapsed);
    await _prefs?.setInt(_kPosesCompleted, posesCompleted);
  }

  Future<void> _clearPrefs() async {
    await _prefs?.remove(_kSplitId);
    await _prefs?.remove(_kAsanaIndex);
    await _prefs?.remove(_kElapsedTime);
    await _prefs?.remove(_kPosesCompleted);
  }
}

final workoutSessionProvider =
    AsyncNotifierProvider<WorkoutSessionNotifier, WorkoutSessionState>(
      WorkoutSessionNotifier.new,
    );
