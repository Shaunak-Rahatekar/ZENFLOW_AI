import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:zenflow_ai/features/workout/domain/pose_analyzer.dart';
import 'package:zenflow_ai/features/workout/providers/workout_session_provider.dart';
import 'package:zenflow_ai/features/workout/services/tts_service.dart';
import 'package:zenflow_ai/features/workout/widgets/skeleton_painter.dart';
import 'package:zenflow_ai/features/workout/models/pose.dart';

class WorkoutSessionScreen extends ConsumerStatefulWidget {
  const WorkoutSessionScreen({super.key});

  @override
  ConsumerState<WorkoutSessionScreen> createState() =>
      _WorkoutSessionScreenState();
}

class _WorkoutSessionScreenState extends ConsumerState<WorkoutSessionScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  // Camera
  CameraController? _cameraController;
  bool _cameraReady = false;
  bool _isFrontCamera = false;
  List<CameraDescription> _availableCameras = [];

  // Pose
  PoseAnalyzer? _poseAnalyzer;
  Pose? _currentPose;
  Interpreter? _interpreter;
  bool _isProcessingFrame = false;
  // Timestamp-based throttle: target ≤ 12 FPS to prevent CPU choking.
  DateTime _lastFrameTime = DateTime.fromMillisecondsSinceEpoch(0);
  static const _minFrameIntervalMs = 1000 ~/ 12; // ~83 ms

  // Timers
  Timer? _masterTimer;

  // Rest ring animation
  late AnimationController _restAnimController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _initPoseAnalyzer();
    _initTfLite();
    _initCamera(CameraLensDirection.back);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final session = ref.read(workoutSessionProvider).value;
      if (session?.status == WorkoutStatus.paused) {
        ref.read(workoutSessionProvider.notifier).resume();
      }
      _startMasterTimer();
    });
  }

  void _initPoseAnalyzer() {
    _poseAnalyzer = PoseAnalyzer(
      onCorrectionNeeded: (correction) {
        TtsService.instance.speak(correction.englishFeedback);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(correction.englishFeedback,
                  style: GoogleFonts.inter(fontWeight: FontWeight.w500)),
              behavior: SnackBarBehavior.floating,
              backgroundColor:
                  Theme.of(context).colorScheme.errorContainer,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 100),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      },
    );
  }

  Future<void> _initTfLite() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/models/movenet_thunder.tflite');
    } catch (e) {
      debugPrint('Error loading model: $e');
    }
  }

  Future<void> _initCamera([
    CameraLensDirection direction = CameraLensDirection.back,
  ]) async {
    // Tear down any existing controller first.
    await _cameraController?.stopImageStream().catchError((_) {});
    await _cameraController?.dispose();
    if (mounted) setState(() => _cameraReady = false);

    try {
      _availableCameras = await availableCameras();
      if (_availableCameras.isEmpty) return;

      final selected = _availableCameras.firstWhere(
        (c) => c.lensDirection == direction,
        orElse: () => _availableCameras.first,
      );

      _cameraController = CameraController(
        selected,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.yuv420
            : ImageFormatGroup.bgra8888,
      );
      await _cameraController!.initialize();
      if (!mounted) return;
      setState(() {
        _cameraReady = true;
        _isFrontCamera = selected.lensDirection == CameraLensDirection.front;
      });

      // Stream frames to TFLite interpreter with timestamp-based throttle.
      await _cameraController!.startImageStream((image) {
        if (_interpreter == null || _isProcessingFrame) return;

        final now = DateTime.now();
        if (now.difference(_lastFrameTime).inMilliseconds <
            _minFrameIntervalMs) return;
        _lastFrameTime = now;

        _isProcessingFrame = true;
        _processFrame(image);
      });
    } catch (_) {
      // Camera unavailable — placeholder shown.
    }
  }

  Future<void> _toggleCamera() async {
    final next = _isFrontCamera
        ? CameraLensDirection.back
        : CameraLensDirection.front;
    await _initCamera(next);
  }

  void _processFrame(CameraImage image) {
    try {
      // Convert image to Tensor format [1, 256, 256, 3] for MoveNet Thunder
      // Note: Full YUV->RGB conversion logic is simplified here for the MVP architecture.
      var input = List.generate(1, (i) => List.generate(256, (j) => List.generate(256, (k) => List.filled(3, 0.0))));
      var output = List.generate(1, (i) => List.generate(1, (j) => List.generate(17, (k) => List.filled(3, 0.0))));
      
      _interpreter!.run(input, output);
      
      // Map Output [1, 1, 17, 3] -> Pose Keypoints
      final keypoints = <KeypointType, Keypoint>{};
      final points = output[0][0];
      for (int i = 0; i < 17; i++) {
        final y = points[i][0];
        final x = points[i][1];
        final score = points[i][2];
        keypoints[KeypointType.values[i]] = Keypoint(x: x, y: y, score: score);
      }
      
      final pose = Pose(keypoints);
      
      if (mounted) {
        setState(() => _currentPose = pose);
        final currentAsana = ref.read(workoutSessionProvider).value?.currentAsana;
        if (currentAsana != null) {
          _poseAnalyzer!.processRawPose(pose, currentAsana);
        }
      }
    } finally {
      _isProcessingFrame = false;
    }
  }

  void _startMasterTimer() {
    _masterTimer?.cancel();
    _masterTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final notifier = ref.read(workoutSessionProvider.notifier);
      final status = ref.read(workoutSessionProvider).value?.status;
      if (status == WorkoutStatus.active) {
        notifier.tick();
        notifier.tickAsana();
      } else if (status == WorkoutStatus.rest) {
        notifier.tick();
        notifier.tickRest();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _masterTimer?.cancel();
      _cameraController?.stopImageStream().catchError((_) {});
      _cameraController?.dispose();
    } else if (state == AppLifecycleState.paused) {
      _masterTimer?.cancel();
      ref.read(workoutSessionProvider.notifier).handleAppBackground();
    } else if (state == AppLifecycleState.resumed) {
      _startMasterTimer();
      if (_cameraController != null && !_cameraController!.value.isInitialized) {
        _initCamera(_isFrontCamera ? CameraLensDirection.front : CameraLensDirection.back);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _masterTimer?.cancel();
    _restAnimController.dispose();
    _cameraController?.dispose();
    _poseAnalyzer?.dispose();
    _interpreter?.close();
    TtsService.instance.stop();
    super.dispose();
  }

  void _onPauseExit() {
    _masterTimer?.cancel();
    ref.read(workoutSessionProvider.notifier).pause();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final sessionAsync = ref.watch(workoutSessionProvider);
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: sessionAsync.when(
        data: (s) => _buildBody(s),
        loading: () =>
            Center(child: CircularProgressIndicator(color: theme.colorScheme.onSurface)),
        error: (e, _) => Center(
            child: Text(e.toString(),
                style: TextStyle(color: theme.colorScheme.onSurface))),
      ),
    );
  }

  Widget _buildBody(WorkoutSessionState session) {
    if (session.status == WorkoutStatus.completed) {
      return _CompletedView(
        elapsedSeconds: session.elapsedSeconds,
        totalAsanas: session.asanas.length,
        onDone: () => Navigator.of(context).pop(),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // ── Layer 1: Camera / Skeleton ─────────────────────────
        _CameraLayer(
          controller: _cameraController,
          isReady: _cameraReady,
          pose: _currentPose,
        ),

        // ── Layer 2: Top HUD ───────────────────────────────────
        SafeArea(
          child: _TopHud(
            session: session,
            onPauseExit: _onPauseExit,
          ),
        ),

        // ── Layer 3: Bottom Controls ───────────────────────────
        Positioned(
          bottom: 32,
          left: 16,
          right: 16,
          child: SafeArea(
            child: _BottomControls(
              session: session,
              onPauseResume: () {
                if (session.status == WorkoutStatus.active) {
                  _masterTimer?.cancel();
                  ref.read(workoutSessionProvider.notifier).pause();
                } else if (session.status == WorkoutStatus.paused) {
                  ref.read(workoutSessionProvider.notifier).resume();
                  _startMasterTimer();
                }
              },
              onNext: () =>
                  ref.read(workoutSessionProvider.notifier).nextAsana(),
            ),
          ),
        ),

        // ── Layer 4: Camera Toggle FAB ────────────────────────────
        if (_cameraReady)
          Positioned(
            bottom: 110,
            right: 20,
            child: SafeArea(
              child: Tooltip(
                message: _isFrontCamera ? 'Switch to Back' : 'Switch to Front',
                child: GestureDetector(
                  onTap: _toggleCamera,
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.55),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Colors.white.withOpacity(0.25), width: 1),
                    ),
                    child: const Icon(
                      Icons.flip_camera_ios_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
              ),
            ),
          ),

        // ── Layer 5: Rest Overlay ──────────────────────────────
        if (session.status == WorkoutStatus.rest)
          _RestOverlay(
            session: session,
            onExtend: () =>
                ref.read(workoutSessionProvider.notifier).extendRest(),
            onSkip: () =>
                ref.read(workoutSessionProvider.notifier).nextAsana(),
          ),
      ],
    );
  }
}

// ── Camera Layer ─────────────────────────────────────────────────────────────

class _CameraLayer extends StatelessWidget {
  const _CameraLayer({
    required this.controller,
    required this.isReady,
    required this.pose,
  });

  final CameraController? controller;
  final bool isReady;
  final Pose? pose;

  @override
  Widget build(BuildContext context) {
    if (!isReady || controller == null) {
      return Container(
        color: const Color(0xFF0A0A0A),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.videocam_off_outlined,
                  size: 56, color: Colors.white.withOpacity(0.15)),
              const SizedBox(height: 12),
              Text(
                'Camera unavailable\nPose detection requires a physical device',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                    color: Colors.white.withOpacity(0.25), fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(controller!),
        if (pose != null)
          CustomPaint(
            painter: SkeletonPainter(pose: pose!),
            child: const SizedBox.expand(),
          ),
      ],
    );
  }
}

// ── Top HUD ──────────────────────────────────────────────────────────────────

class _TopHud extends StatelessWidget {
  const _TopHud({required this.session, required this.onPauseExit});

  final WorkoutSessionState session;
  final VoidCallback onPauseExit;

  String _fmtTime(int s) {
    final m = s ~/ 60;
    final sec = s % 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final asana = session.currentAsana;
    final name = asana?['english_name'] as String? ?? 'Get Ready';
    final sanskrit = asana?['sanskrit_name'] as String? ?? '';
    final progress = session.asanaProgress;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withOpacity(0.75), Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Asana info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: GoogleFonts.inter(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: Colors.white),
                    ),
                    if (sanskrit.isNotEmpty)
                      Text(sanskrit,
                          style: GoogleFonts.inter(
                              fontSize: 13,
                              color: Colors.white54,
                              fontStyle: FontStyle.italic)),
                    const SizedBox(height: 4),
                    Text(
                      'Asana ${session.currentAsanaIndex + 1} of ${session.asanas.length}',
                      style: GoogleFonts.inter(
                          fontSize: 12, color: Colors.white54),
                    ),
                  ],
                ),
              ),

              // Dual timer column
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Asana countdown ring
                  _CountdownRing(
                    progress: progress,
                    label: _fmtTime(session.asanaCountdownSeconds),
                    size: 72,
                    color: const Color(0xFF00E5FF),
                  ),
                  const SizedBox(height: 6),
                  // Session stopwatch
                  Row(
                    children: [
                      const Icon(Icons.timer_outlined,
                          color: Colors.white54, size: 13),
                      const SizedBox(width: 4),
                      Text(
                        _fmtTime(session.elapsedSeconds),
                        style: GoogleFonts.inter(
                            fontSize: 12, color: Colors.white54),
                      ),
                    ],
                  ),
                ],
              ),

              // Exit button
              IconButton(
                icon: const Icon(Icons.close_rounded,
                    color: Colors.white, size: 22),
                onPressed: onPauseExit,
                tooltip: 'Pause & Exit',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Countdown Ring ────────────────────────────────────────────────────────────

class _CountdownRing extends StatelessWidget {
  const _CountdownRing({
    required this.progress,
    required this.label,
    required this.size,
    required this.color,
  });

  final double progress;
  final String label;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 4,
              backgroundColor: Colors.white.withOpacity(0.12),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          Text(
            label,
            style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Colors.white),
          ),
        ],
      ),
    );
  }
}

// ── Bottom Controls ───────────────────────────────────────────────────────────

class _BottomControls extends StatelessWidget {
  const _BottomControls({
    required this.session,
    required this.onPauseResume,
    required this.onNext,
  });

  final WorkoutSessionState session;
  final VoidCallback onPauseResume;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final isPaused = session.status == WorkoutStatus.paused;
    return Row(
      children: [
        Expanded(
          child: _GlassButton(
            icon: isPaused
                ? Icons.play_arrow_rounded
                : Icons.pause_rounded,
            label: isPaused ? 'Resume' : 'Pause',
            onTap: onPauseResume,
            primary: false,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _GlassButton(
            icon: Icons.skip_next_rounded,
            label: 'Next',
            onTap: onNext,
            primary: true,
          ),
        ),
      ],
    );
  }
}

class _GlassButton extends StatelessWidget {
  const _GlassButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.primary,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: primary
              ? theme.colorScheme.primary.withOpacity(0.85)
              : Colors.white.withOpacity(0.12),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
              color: Colors.white.withOpacity(0.2), width: 0.8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(label,
                style: GoogleFonts.inter(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 15)),
          ],
        ),
      ),
    );
  }
}

// ── Rest Overlay ──────────────────────────────────────────────────────────────

class _RestOverlay extends StatelessWidget {
  const _RestOverlay({
    required this.session,
    required this.onExtend,
    required this.onSkip,
  });

  final WorkoutSessionState session;
  final VoidCallback onExtend;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = session.restSecondsRemaining;
    final progress = session.restProgress;
    final next = session.nextAsana;
    final extensionsLeft = 3 - session.restExtensions;

    return Container(
      color: Colors.black.withOpacity(0.82),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // REST badge
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: theme.colorScheme.primary.withOpacity(0.5)),
                ),
                child: Text(
                  'REST',
                  style: GoogleFonts.inter(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 3,
                      fontSize: 13),
                ),
              ),

              const SizedBox(height: 28),

              // Big countdown ring
              _CountdownRing(
                progress: progress,
                label: remaining.toString(),
                size: 140,
                color: theme.colorScheme.primary,
              ),

              const SizedBox(height: 8),
              Text('seconds remaining',
                  style: GoogleFonts.inter(
                      color: Colors.white54, fontSize: 14)),

              const SizedBox(height: 36),

              // Next asana preview card
              if (next != null) ...[
                Text('COMING UP',
                    style: GoogleFonts.inter(
                        color: Colors.white38,
                        fontSize: 11,
                        letterSpacing: 2,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: Colors.white.withOpacity(0.12)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        next['english_name'] as String? ?? '',
                        style: GoogleFonts.inter(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700),
                      ),
                      if ((next['sanskrit_name'] as String?)
                              ?.isNotEmpty ??
                          false)
                        Text(
                          next['sanskrit_name'] as String,
                          style: GoogleFonts.inter(
                              color: Colors.white38,
                              fontSize: 13,
                              fontStyle: FontStyle.italic),
                        ),
                      const SizedBox(height: 6),
                      Text(
                        '${(next['duration_seconds'] as int?) ?? 60}s hold',
                        style: GoogleFonts.inter(
                            color: theme.colorScheme.primary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],

              // +1 min button
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          session.canExtendRest ? onExtend : null,
                      style: OutlinedButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(
                          color: session.canExtendRest
                              ? theme.colorScheme.primary
                              : Colors.white24,
                        ),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      icon: Icon(Icons.add_alarm_rounded,
                          color: session.canExtendRest
                              ? theme.colorScheme.primary
                              : Colors.white24,
                          size: 18),
                      label: Text(
                        session.canExtendRest
                            ? '+1 min  ($extensionsLeft left)'
                            : 'No extensions left',
                        style: GoogleFonts.inter(
                          color: session.canExtendRest
                              ? theme.colorScheme.primary
                              : Colors.white24,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Skip Rest
                  OutlinedButton(
                    onPressed: onSkip,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          vertical: 14, horizontal: 20),
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: Text('Skip',
                        style: GoogleFonts.inter(
                            color: Colors.white54,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Completed View ────────────────────────────────────────────────────────────

class _CompletedView extends StatelessWidget {
  const _CompletedView({
    required this.elapsedSeconds,
    required this.totalAsanas,
    required this.onDone,
  });

  final int elapsedSeconds;
  final int totalAsanas;
  final VoidCallback onDone;

  String _fmtTime(int s) {
    final m = s ~/ 60;
    final sec = s % 60;
    return '${m.toString().padLeft(2, '0')}m ${sec.toString().padLeft(2, '0')}s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFF0A1628),
            theme.colorScheme.primary.withOpacity(0.15),
            const Color(0xFF0A1628),
          ],
        ),
      ),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withOpacity(0.15),
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: theme.colorScheme.primary.withOpacity(0.4),
                        width: 2),
                  ),
                  child: Icon(Icons.self_improvement_rounded,
                      size: 64, color: theme.colorScheme.primary),
                ),
                const SizedBox(height: 28),
                Text('Session Complete!',
                    style: GoogleFonts.inter(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: Colors.white)),
                const SizedBox(height: 8),
                Text('Outstanding work. Keep the flow going.',
                    style: GoogleFonts.inter(
                        fontSize: 15, color: Colors.white54)),
                const SizedBox(height: 32),

                // Stats row
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _StatChip(
                        icon: Icons.timer_outlined,
                        label: _fmtTime(elapsedSeconds)),
                    const SizedBox(width: 16),
                    _StatChip(
                        icon: Icons.self_improvement_rounded,
                        label: '$totalAsanas asanas'),
                  ],
                ),
                const SizedBox(height: 40),

                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: onDone,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                    ),
                    child: Text('Back to Dashboard',
                        style: GoogleFonts.inter(
                            fontWeight: FontWeight.w700, fontSize: 16)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white60, size: 16),
          const SizedBox(width: 8),
          Text(label,
              style: GoogleFonts.inter(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14)),
        ],
      ),
    );
  }
}
