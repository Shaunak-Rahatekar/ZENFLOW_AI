import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

// Keys for SharedPreferences persistence
const _kSplitId = 'session_split_id';
const _kAsanaIndex = 'session_asana_index';
const _kElapsedTime = 'session_elapsed_time';

const int _kDefaultAsanaDuration = 60; // seconds
const int _kRestDuration = 15; // seconds
const int _kMaxRestExtensions = 3;

/// Represents the possible states of a live workout session
enum WorkoutStatus { idle, loading, active, paused, rest, completed }

/// Holds all relevant state for the current workout session
class WorkoutSessionState {
  final WorkoutStatus status;
  final String? splitId;
  final int currentAsanaIndex;
  final int elapsedSeconds;        // total session stopwatch (counts up)
  final int asanaCountdownSeconds; // per-asana countdown (counts down)
  final int restSecondsRemaining;  // rest overlay countdown (counts down)
  final int restExtensions;        // how many times +1min has been used
  final Map<String, dynamic>? currentAsana;
  final List<dynamic> asanas;
  final String? errorMessage;

  const WorkoutSessionState({
    this.status = WorkoutStatus.idle,
    this.splitId,
    this.currentAsanaIndex = 0,
    this.elapsedSeconds = 0,
    this.asanaCountdownSeconds = _kDefaultAsanaDuration,
    this.restSecondsRemaining = _kRestDuration,
    this.restExtensions = 0,
    this.currentAsana,
    this.asanas = const [],
    this.errorMessage,
  });

  WorkoutSessionState copyWith({
    WorkoutStatus? status,
    String? splitId,
    int? currentAsanaIndex,
    int? elapsedSeconds,
    int? asanaCountdownSeconds,
    int? restSecondsRemaining,
    int? restExtensions,
    Map<String, dynamic>? currentAsana,
    List<dynamic>? asanas,
    String? errorMessage,
  }) {
    return WorkoutSessionState(
      status: status ?? this.status,
      splitId: splitId ?? this.splitId,
      currentAsanaIndex: currentAsanaIndex ?? this.currentAsanaIndex,
      elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
      asanaCountdownSeconds: asanaCountdownSeconds ?? this.asanaCountdownSeconds,
      restSecondsRemaining: restSecondsRemaining ?? this.restSecondsRemaining,
      restExtensions: restExtensions ?? this.restExtensions,
      currentAsana: currentAsana ?? this.currentAsana,
      asanas: asanas ?? this.asanas,
      errorMessage: errorMessage,
    );
  }

  /// Duration for the current asana, pulled from JSON or default
  int get currentAsanaDuration {
    final dur = currentAsana?['duration_seconds'];
    if (dur is int) return dur;
    if (dur is num) return dur.toInt();
    if (dur is String) return int.tryParse(dur) ?? _kDefaultAsanaDuration;
    return _kDefaultAsanaDuration;
  }

  /// Progress fraction [0.0 – 1.0] for the per-asana countdown ring
  double get asanaProgress {
    final total = currentAsanaDuration;
    if (total <= 0) return 0.0;
    return (1.0 - (asanaCountdownSeconds / total)).clamp(0.0, 1.0);
  }

  /// Progress fraction [0.0 – 1.0] for the rest countdown
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
}

/// Riverpod AsyncNotifier for the workout session
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

  Future<void> _syncPendingLogs() async {
    final pendingLogsStr = await _secureStorage.read(key: 'pending_sync_logs');
    List<String> pendingLogs = [];
    if (pendingLogsStr != null && pendingLogsStr.isNotEmpty) {
      pendingLogs = List<String>.from(jsonDecode(pendingLogsStr));
    }
    if (pendingLogs.isEmpty) return;

    List<String> remainingLogs = [];
    for (String logJson in pendingLogs) {
      try {
        final logMap = jsonDecode(logJson);
        await Supabase.instance.client.from('workout_logs').insert(logMap);
      } catch (_) {
        remainingLogs.add(logJson); // Keep if still failing
      }
    }
    await _secureStorage.write(key: 'pending_sync_logs', value: jsonEncode(remainingLogs));
  }

  Future<WorkoutSessionState> _rehydrateSession() async {
    final savedSplitId = _prefs?.getString(_kSplitId);
    final savedAsanaIndex = _prefs?.getInt(_kAsanaIndex);
    final savedElapsed = _prefs?.getInt(_kElapsedTime);

    if (savedSplitId != null && savedAsanaIndex != null) {
      return WorkoutSessionState(
        status: WorkoutStatus.paused,
        splitId: savedSplitId,
        currentAsanaIndex: savedAsanaIndex,
        elapsedSeconds: savedElapsed ?? 0,
      );
    }
    return const WorkoutSessionState(status: WorkoutStatus.idle);
  }

  /// Starts a new workout or resumes a paused one
  Future<void> startOrResume(
    String splitId,
    List<dynamic> asanas, {
    int fromIndex = 0,
    int fromElapsed = 0,
  }) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final startIndex = state.value?.currentAsanaIndex ?? fromIndex;
      final asana = asanas.isNotEmpty ? asanas[startIndex] as Map<String, dynamic>? : null;
      final durVal = asana?['duration_seconds'];
      final duration = durVal is int ? durVal : (durVal is num ? durVal.toInt() : (durVal is String ? int.tryParse(durVal) ?? _kDefaultAsanaDuration : _kDefaultAsanaDuration));
      return WorkoutSessionState(
        status: WorkoutStatus.active,
        splitId: splitId,
        currentAsanaIndex: startIndex,
        elapsedSeconds: state.value?.elapsedSeconds ?? fromElapsed,
        asanaCountdownSeconds: duration,
        asanas: asanas,
        currentAsana: asana,
      );
    });
  }

  /// Pauses the session and persists state to SharedPreferences
  Future<void> pause() async {
    final current = state.hasValue ? state.value : null;
    if (current == null || current.status != WorkoutStatus.active) return;

    await _saveToPrefs(
      splitId: current.splitId!,
      asanaIndex: current.currentAsanaIndex,
      elapsed: current.elapsedSeconds,
    );

    state = AsyncData(current.copyWith(status: WorkoutStatus.paused));
  }

  /// Resumes a paused or resting session
  void resume() {
    final current = state.hasValue ? state.value : null;
    if (current == null ||
        (current.status != WorkoutStatus.paused &&
            current.status != WorkoutStatus.rest)) return;
    state = AsyncData(current.copyWith(status: WorkoutStatus.active));
  }

  /// Enters rest state — called after per-asana countdown hits 0
  void rest() {
    final current = state.hasValue ? state.value : null;
    if (current == null || current.status != WorkoutStatus.active) return;
    state = AsyncData(current.copyWith(
      status: WorkoutStatus.rest,
      restSecondsRemaining: _kRestDuration,
    ));
  }

  /// Extends rest by 60 seconds (max 3 times)
  void extendRest() {
    final current = state.hasValue ? state.value : null;
    if (current == null || current.status != WorkoutStatus.rest) return;
    if (!current.canExtendRest) return;
    state = AsyncData(current.copyWith(
      restSecondsRemaining: current.restSecondsRemaining + 60,
      restExtensions: current.restExtensions + 1,
    ));
  }

  /// Advances to the next asana; resets per-asana countdown
  void nextAsana() {
    final current = state.hasValue ? state.value : null;
    if (current == null) return;
    final nextIndex = current.currentAsanaIndex + 1;

    if (nextIndex >= current.asanas.length) {
      _completeSession();
      return;
    }

    final nextAsana = current.asanas[nextIndex] as Map<String, dynamic>?;
    final durVal = nextAsana?['duration_seconds'];
    final duration = durVal is int ? durVal : (durVal is num ? durVal.toInt() : (durVal is String ? int.tryParse(durVal) ?? _kDefaultAsanaDuration : _kDefaultAsanaDuration));

    state = AsyncData(current.copyWith(
      status: WorkoutStatus.active,
      currentAsanaIndex: nextIndex,
      currentAsana: nextAsana,
      asanaCountdownSeconds: duration,
      restSecondsRemaining: _kRestDuration,
      restExtensions: 0,
    ));
  }

  /// Session-wide elapsed timer tick (call every second while active or resting)
  void tick() {
    final current = state.hasValue ? state.value : null;
    if (current == null ||
        (current.status != WorkoutStatus.active &&
            current.status != WorkoutStatus.rest)) return;
    state = AsyncData(
        current.copyWith(elapsedSeconds: current.elapsedSeconds + 1));
  }

  /// Per-asana countdown tick (call every second while active)
  void tickAsana() {
    final current = state.hasValue ? state.value : null;
    if (current == null || current.status != WorkoutStatus.active) return;

    final next = current.asanaCountdownSeconds - 1;
    if (next <= 0) {
      // Asana done → transition to rest
      rest();
    } else {
      state = AsyncData(current.copyWith(asanaCountdownSeconds: next));
    }
  }

  /// Rest overlay countdown tick (call every second while resting)
  void tickRest() {
    final current = state.hasValue ? state.value : null;
    if (current == null || current.status != WorkoutStatus.rest) return;

    final next = current.restSecondsRemaining - 1;
    if (next <= 0) {
      nextAsana();
    } else {
      state = AsyncData(current.copyWith(restSecondsRemaining: next));
    }
  }

  /// Auto-pauses when app goes to background
  Future<void> handleAppBackground() async {
    final current = state.hasValue ? state.value : null;
    if (current?.status == WorkoutStatus.active ||
        current?.status == WorkoutStatus.rest) {
      await pause();
    }
  }

  Future<void> _completeSession() async {
    final current = state.hasValue ? state.value : null;
    await _clearPrefs();

    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null && current?.splitId != null) {
        final logData = {
          'user_id': user.id,
          'split_id': current!.splitId,
          'asana_id': 'Daily Flow',
          'workout_date': DateTime.now().toIso8601String().split('T')[0],
          'started_at': DateTime.now()
              .subtract(Duration(seconds: current.elapsedSeconds))
              .toIso8601String(),
          'completed_at': DateTime.now().toIso8601String(),
          'duration_minutes': current.elapsedSeconds ~/ 60,
        };
        try {
          await Supabase.instance.client.from('workout_logs').insert(logData);
        } catch (_) {
          // Offline Fallback
          final pendingLogsStr = await _secureStorage.read(key: 'pending_sync_logs');
          List<String> pending = [];
          if (pendingLogsStr != null && pendingLogsStr.isNotEmpty) {
            pending = List<String>.from(jsonDecode(pendingLogsStr));
          }
          pending.add(jsonEncode(logData));
          await _secureStorage.write(key: 'pending_sync_logs', value: jsonEncode(pending));
        }
      }
    } catch (_) {
      // Log silently — don't block session completion
    }

    state = AsyncData(const WorkoutSessionState(status: WorkoutStatus.completed));
  }

  /// Discards the current or paused session
  Future<void> cancelSession() async {
    await _clearPrefs();
    state = const AsyncData(WorkoutSessionState(status: WorkoutStatus.idle));
  }

  /// Calculates the current Day Index based on the split's start_date
  Future<void> checkAndResetWorkout() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    try {
      final response = await Supabase.instance.client
          .from('weekly_splits')
          .select('start_date, split_data')
          .eq('user_id', user.id)
          .order('start_date', ascending: false)
          .limit(1)
          .maybeSingle();

      if (response == null) return;

      final startDate = DateTime.parse(response['start_date'] as String);
      final now = DateTime.now();
      final dayIndex = now.difference(startDate).inDays;

      if (dayIndex >= 0 && dayIndex < 7) {
        final splitData = response['split_data'] as List<dynamic>?;
        if (splitData != null && splitData.length > dayIndex) {
          // Day asanas are ready — caller can use checkAndResetWorkout result
        }
      } else if (dayIndex >= 7) {
        // Trigger fresh workout generation
        await Supabase.instance.client.functions.invoke(
          'generate_workout',
          body: {'user_id': user.id},
        );
      }
    } catch (e) {
      state = AsyncError(e, StackTrace.current);
    }
  }

  Future<void> _saveToPrefs({
    required String splitId,
    required int asanaIndex,
    required int elapsed,
  }) async {
    await _prefs?.setString(_kSplitId, splitId);
    await _prefs?.setInt(_kAsanaIndex, asanaIndex);
    await _prefs?.setInt(_kElapsedTime, elapsed);
  }

  Future<void> _clearPrefs() async {
    await _prefs?.remove(_kSplitId);
    await _prefs?.remove(_kAsanaIndex);
    await _prefs?.remove(_kElapsedTime);
  }
}

/// The global provider for the WorkoutSession
final workoutSessionProvider =
    AsyncNotifierProvider<WorkoutSessionNotifier, WorkoutSessionState>(
  WorkoutSessionNotifier.new,
);
