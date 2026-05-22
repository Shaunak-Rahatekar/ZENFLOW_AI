import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:zenflow_ai/features/auth/screens/profile_screen.dart';
import 'package:zenflow_ai/features/dashboard/providers/dashboard_stats_provider.dart';
import 'package:zenflow_ai/features/dashboard/widgets/stat_card.dart';
import 'package:zenflow_ai/features/dashboard/widgets/continue_workout_button.dart';
import 'package:zenflow_ai/features/workout/providers/workout_session_provider.dart';
import 'package:zenflow_ai/features/workout/screens/workout_session_screen.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen>
    with WidgetsBindingObserver {
  bool _hasCheckedResume = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// App lifecycle observer – auto-pause on background
  @override
  void didChangeAppLifecycleState(AppLifecycleState appState) {
    if (appState == AppLifecycleState.paused ||
        appState == AppLifecycleState.detached) {
      ref.read(workoutSessionProvider.notifier).handleAppBackground();
    }
  }

  void _launchWorkout(BuildContext context, WorkoutSessionState session) async {
    // If there's no active split loaded yet, fetch it from Supabase first
    if (session.status == WorkoutStatus.idle) {
      await ref.read(workoutSessionProvider.notifier).fetchAndStartWorkout();
      final updated = ref.read(workoutSessionProvider).value;
      if (updated == null || updated.status == WorkoutStatus.idle) return;
    }

    if (!context.mounted) return;
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const WorkoutSessionScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.0, 0.05),
                end: Offset.zero,
              ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
              child: child,
            ),
          );
        },
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  void _showResumeDialog(WorkoutSessionState session) {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('Resume Workout?', style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
        content: Text(
          'You have an unfinished workout session. Would you like to resume it?',
          style: GoogleFonts.inter(),
        ),
        actions: [
          TextButton(
            onPressed: () {
              ref.read(workoutSessionProvider.notifier).cancelSession();
              Navigator.of(context).pop();
            },
            child: Text('Discard', style: GoogleFonts.inter(color: Theme.of(context).colorScheme.error)),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              _launchWorkout(context, session);
            },
            child: Text('Resume', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Listen for workout completion → immediately refresh stats and reports
    ref.listen<AsyncValue<WorkoutSessionState>>(workoutSessionProvider, (previous, next) {
      final prevStatus = previous?.value?.status;
      final nextStatus = next.value?.status;

      // Refresh dashboard when a session completes
      if (prevStatus != WorkoutStatus.completed && nextStatus == WorkoutStatus.completed) {
        ref.invalidate(dashboardStatsProvider);
      }

      if (!_hasCheckedResume &&
          next is AsyncData &&
          next.value?.status == WorkoutStatus.paused &&
          (next.value?.asanas.isNotEmpty ?? false)) {
        _hasCheckedResume = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showResumeDialog(next.value!);
        });
      } else if (next is AsyncData && next.value?.status == WorkoutStatus.idle) {
        _hasCheckedResume = true;
      }
    });

    final theme = Theme.of(context);
    final statsAsync = ref.watch(dashboardStatsProvider);
    final sessionAsync = ref.watch(workoutSessionProvider);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── App Bar ─────────────────────────────────────────
          SliverAppBar(
            expandedHeight: 120,
            floating: true,
            pinned: true,
            backgroundColor: theme.colorScheme.surface,
            elevation: 0,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                'ZenFlow AI',
                style: GoogleFonts.inter(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              titlePadding: const EdgeInsetsDirectional.only(start: 20, bottom: 16),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.person_outline_rounded),
                tooltip: 'Profile',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ProfileScreen()),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),

          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                const SizedBox(height: 8),

                // ── Greeting ─────────────────────────────────
                Text(
                  'Good ${_greeting()},',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: theme.colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
                Text(
                  'Ready to flow?',
                  style: GoogleFonts.inter(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),

                const SizedBox(height: 28),

                // ── CTA Button (Start / Continue) ─────────────
                sessionAsync.when(
                  data: (session) => ContinueWorkoutButton(
                    session: session,
                    onTap: () => _launchWorkout(context, session),
                  ),
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => _ErrorCard(message: e.toString()),
                ),

                const SizedBox(height: 32),

                // ── Section Title ─────────────────────────────
                Text(
                  'Your Stats',
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),

                const SizedBox(height: 14),

                // ── Stat Cards ────────────────────────────────
                statsAsync.when(
                  data: (stats) => stats.isSyncing
                      ? const _SyncingPlaceholder()
                      : _StatsGrid(stats: stats),
                  loading: () => const _StatsGridSkeleton(),
                  error: (e, _) => const _SyncingPlaceholder(),
                ),

                const SizedBox(height: 40),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Morning';
    if (hour < 17) return 'Afternoon';
    return 'Evening';
  }
}

// ── Stats Grid ───────────────────────────────────────────────────────────────

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.stats});
  final DashboardStats stats;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: StatCard(
            icon: Icons.fitness_center_rounded,
            label: 'Total Workouts',
            value: stats.totalWorkouts.toString(),
            color: Colors.teal,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: StatCard(
            icon: Icons.local_fire_department_rounded,
            label: 'Day Streak',
            value: '${stats.currentStreak} 🔥',
            color: Colors.orange,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: StatCard(
            icon: Icons.bolt_rounded,
            label: "Today's Cal",
            value: '${stats.todayCalories} kcal',
            color: Colors.purple,
          ),
        ),
      ],
    );
  }
}

class _StatsGridSkeleton extends StatelessWidget {
  const _StatsGridSkeleton();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(3, (i) => Expanded(
        child: Padding(
          padding: EdgeInsets.only(right: i < 2 ? 12 : 0),
          child: Container(
            height: 110,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      )),
    );
  }
}

/// Shown when workout_logs table is not yet reachable (PGRST205 / offline).
class _SyncingPlaceholder extends StatelessWidget {
  const _SyncingPlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'Syncing with Cloud...',
            style: GoogleFonts.inter(
              fontSize: 13,
              color: theme.colorScheme.onSurface.withOpacity(0.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(message,
          style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
    );
  }
}
