import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:zenflow_ai/features/workout/providers/workout_session_provider.dart';

class ContinueWorkoutButton extends StatelessWidget {
  const ContinueWorkoutButton({
    super.key,
    required this.session,
    required this.onTap,
  });

  final WorkoutSessionState session;
  final VoidCallback onTap;

  bool get _hasActiveSession =>
      session.status == WorkoutStatus.paused && session.splitId != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dayLabel = 'Day ${session.currentAsanaIndex + 1}';

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: _hasActiveSession
                ? [
                    theme.colorScheme.primary,
                    theme.colorScheme.primary.withOpacity(0.75),
                  ]
                : [
                    theme.colorScheme.primary,
                    const Color(0xFF00897B),
                  ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.primary.withOpacity(0.35),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Label & Icon
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _hasActiveSession
                            ? Icons.play_arrow_rounded
                            : Icons.self_improvement_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _hasActiveSession
                              ? 'Continue $dayLabel'
                              : 'Start Workout',
                          style: GoogleFonts.inter(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        Text(
                          _hasActiveSession
                              ? _formatElapsed(session.elapsedSeconds)
                              : 'Begin your AI-guided session',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: Colors.white.withOpacity(0.8),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ],
            ),

            // Progress bar (only for active session)
            if (_hasActiveSession) ...[
              const SizedBox(height: 18),
              _ProgressBar(
                progress: session.asanas.isEmpty
                    ? 0
                    : session.currentAsanaIndex / session.asanas.length,
                label:
                    '${session.currentAsanaIndex} of ${session.asanas.length} asanas completed',
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatElapsed(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')} elapsed · tap to resume';
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.progress, required this.label});
  final double progress;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: progress.clamp(0.0, 1.0),
            backgroundColor: Colors.white.withOpacity(0.25),
            valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
            minHeight: 6,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            color: Colors.white.withOpacity(0.75),
          ),
        ),
      ],
    );
  }
}
