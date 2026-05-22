import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:zenflow_ai/features/workout/domain/pose_analyzer.dart';
import 'package:zenflow_ai/features/workout/providers/workout_session_provider.dart';
import 'package:zenflow_ai/features/workout/services/tts_service.dart';
import 'package:zenflow_ai/features/workout/widgets/skeleton_painter.dart';
import 'package:zenflow_ai/features/workout/models/pose.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ── Isolate message types ─────────────────────────────────────────────────────

/// Sent from main isolate → worker isolate with raw camera plane data.
/// We send raw planes instead of pre-converted RGB so the UI thread
/// does zero pixel work — the conversion happens entirely in the isolate.
class _FrameRequest {
  final SendPort replyPort;
  // YUV420 planes (Android) or single BGRA plane (iOS)
  final Uint8List plane0;          // Y plane (YUV) or BGRA plane (iOS)
  final Uint8List? plane1;         // U plane (YUV only)
  final Uint8List? plane2;         // V plane (YUV only)
  final int plane0RowStride;
  final int plane1RowStride;
  final int plane1PixelStride;
  final int srcWidth;
  final int srcHeight;
  final bool isYuv;                // true = YUV420 (Android), false = BGRA (iOS)
  final bool isFront;
  final int sensorOrientation;

  _FrameRequest({
    required this.replyPort,
    required this.plane0,
    this.plane1,
    this.plane2,
    required this.plane0RowStride,
    this.plane1RowStride = 0,
    this.plane1PixelStride = 2,
    required this.srcWidth,
    required this.srcHeight,
    required this.isYuv,
    required this.isFront,
    required this.sensorOrientation,
  });
}

/// Sent from worker isolate → main isolate with parsed keypoints.
class _FrameResult {
  /// 17 entries: each is [x_norm, y_norm, score]
  final List<List<double>> keypoints;
  _FrameResult(this.keypoints);
}

/// Top-level function that runs in the worker isolate.
/// Does pixel conversion + MoveNet inference entirely off the UI thread.
/// Receives the model bytes as the first message, then processes frames.
void _inferenceWorker(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  Interpreter? interpreter;

  receivePort.listen((message) async {
    if (message is String && message == 'dispose') {
      interpreter?.close();
      receivePort.close();
      return;
    }

    // First message after SendPort handshake is the model bytes from main isolate
    if (message is Uint8List && interpreter == null) {
      try {
        interpreter = Interpreter.fromBuffer(message);
        debugPrint('[Isolate] Interpreter loaded from buffer, input: ${interpreter!.getInputTensors().map((t) => t.shape)}');
      } catch (e) {
        debugPrint('[Isolate] Failed to load interpreter: $e');
      }
      return;
    }

    if (message is! _FrameRequest) return;
    if (interpreter == null) {
      // Model not loaded yet — send empty result
      message.replyPort.send(_FrameResult(List.generate(17, (_) => [0.0, 0.0, 0.0])));
      return;
    }

    try {
      const int modelSize = 256;
      final pixels = Uint8List(modelSize * modelSize * 3);

      if (message.isYuv) {
        _yuv420ToRgbIsolate(message, pixels, modelSize);
      } else {
        _bgraToRgbIsolate(message, pixels, modelSize);
      }

      final input = _reshapeRgbToInput(pixels, modelSize);
      final output = List.generate(
        1, (_) => List.generate(1, (_) => List.generate(17, (_) => List.filled(3, 0.0))),
      );

      interpreter!.run(input, output);

      final points = output[0][0];
      final keypoints = <List<double>>[];
      for (int i = 0; i < 17; i++) {
        final y = (points[i][0] as num).toDouble();
        var x = (points[i][1] as num).toDouble();
        final score = (points[i][2] as num).toDouble();
        if (message.isFront) x = 1.0 - x;
        keypoints.add([x, y, score]);
      }

      message.replyPort.send(_FrameResult(keypoints));
    } catch (e) {
      debugPrint('[Isolate] Inference error: $e');
      message.replyPort.send(_FrameResult(List.generate(17, (_) => [0.0, 0.0, 0.0])));
    }
  });
}

void _yuv420ToRgbIsolate(_FrameRequest msg, Uint8List out, int size) {
  final yPlane = msg.plane0;
  final uPlane = msg.plane1!;
  final vPlane = msg.plane2!;
  final int srcW = msg.srcWidth;
  final int srcH = msg.srcHeight;
  final int yRowStride = msg.plane0RowStride;
  final int uvRowStride = msg.plane1RowStride;
  final int uvPixelStride = msg.plane1PixelStride;

  for (int row = 0; row < size; row++) {
    for (int col = 0; col < size; col++) {
      int srcX, srcY;
      switch (msg.sensorOrientation) {
        case 90:
          srcX = (row * srcW / size).floor();
          srcY = srcH - 1 - (col * srcH / size).floor();
          break;
        case 270:
          srcX = srcW - 1 - (row * srcW / size).floor();
          srcY = (col * srcH / size).floor();
          break;
        case 180:
          srcX = srcW - 1 - (col * srcW / size).floor();
          srcY = srcH - 1 - (row * srcH / size).floor();
          break;
        default:
          srcX = (col * srcW / size).floor();
          srcY = (row * srcH / size).floor();
      }
      srcX = srcX.clamp(0, srcW - 1);
      srcY = srcY.clamp(0, srcH - 1);

      final int yIdx = srcY * yRowStride + srcX;
      final int uvIdx = (srcY ~/ 2) * uvRowStride + (srcX ~/ 2) * uvPixelStride;

      final int yv = yPlane[yIdx];
      final int uv = uPlane[uvIdx];
      final int vv = vPlane[uvIdx];

      final int r = (yv + 1.402 * (vv - 128)).round().clamp(0, 255);
      final int g = (yv - 0.344136 * (uv - 128) - 0.714136 * (vv - 128)).round().clamp(0, 255);
      final int b = (yv + 1.772 * (uv - 128)).round().clamp(0, 255);

      final int idx = (row * size + col) * 3;
      out[idx] = r; out[idx + 1] = g; out[idx + 2] = b;
    }
  }
}

void _bgraToRgbIsolate(_FrameRequest msg, Uint8List out, int size) {
  final bytes = msg.plane0;
  final int srcW = msg.srcWidth;
  final int srcH = msg.srcHeight;
  final int rowStride = msg.plane0RowStride;

  for (int row = 0; row < size; row++) {
    for (int col = 0; col < size; col++) {
      int srcX, srcY;
      switch (msg.sensorOrientation) {
        case 90:
          srcX = (row * srcW / size).floor();
          srcY = srcH - 1 - (col * srcH / size).floor();
          break;
        case 270:
          srcX = srcW - 1 - (row * srcW / size).floor();
          srcY = (col * srcH / size).floor();
          break;
        case 180:
          srcX = srcW - 1 - (col * srcW / size).floor();
          srcY = srcH - 1 - (row * srcH / size).floor();
          break;
        default:
          srcX = (col * srcW / size).floor();
          srcY = (row * srcH / size).floor();
      }
      srcX = srcX.clamp(0, srcW - 1);
      srcY = srcY.clamp(0, srcH - 1);

      final int srcIdx = srcY * rowStride + srcX * 4;
      final int outIdx = (row * size + col) * 3;
      out[outIdx]     = bytes[srcIdx + 2]; // R
      out[outIdx + 1] = bytes[srcIdx + 1]; // G
      out[outIdx + 2] = bytes[srcIdx];     // B
    }
  }
}

List _reshapeRgbToInput(Uint8List flat, int size) {
  return List.generate(1, (_) =>
    List.generate(size, (row) =>
      List.generate(size, (col) {
        final base = (row * size + col) * 3;
        return [flat[base], flat[base + 1], flat[base + 2]];
      })
    )
  );
}

class WorkoutSessionScreen extends ConsumerStatefulWidget {
  const WorkoutSessionScreen({super.key});

  @override
  ConsumerState<WorkoutSessionScreen> createState() =>
      _WorkoutSessionScreenState();
}

class _WorkoutSessionScreenState extends ConsumerState<WorkoutSessionScreen>
    with WidgetsBindingObserver {
  // ── Camera ──────────────────────────────────────────────────────────────────
  CameraController? _cameraController;
  bool _cameraReady = false;
  bool _isFrontCamera = false;
  List<CameraDescription> _availableCameras = [];

  // ── Pose ────────────────────────────────────────────────────────────────────
  PoseAnalyzer? _poseAnalyzer;
  Pose? _currentPose;
  // Isolate-based inference — keeps UI thread free so timer never freezes
  Isolate? _inferenceIsolate;
  SendPort? _isolateSendPort;
  bool _isolateReady = false;
  bool _isProcessingFrame = false;
  DateTime _lastFrameTime = DateTime.fromMillisecondsSinceEpoch(0);
  // Target ~10 FPS for inference (100ms between frames)
  static const _minFrameIntervalMs = 100;

  // ── Master timer ────────────────────────────────────────────────────────────
  // Uses a Stopwatch-based approach to detect and recover from skipped ticks.
  Timer? _masterTimer;
  final Stopwatch _timerStopwatch = Stopwatch();
  int _lastTickMs = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _initPoseAnalyzer();
    _initInferenceIsolate();
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
              content: Text(
                correction.englishFeedback,
                style: GoogleFonts.inter(fontWeight: FontWeight.w500),
              ),
              behavior: SnackBarBehavior.floating,
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 100),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      },
      onMotivationNeeded: () {
        TtsService.instance.speakMotivation();
      },
      onAccuracyUpdate: (accuracy) {
        if (mounted) {
          ref.read(workoutSessionProvider.notifier).updateAccuracy(accuracy);
        }
      },
    );
  }

  /// Spawns the inference isolate, then loads model bytes on the main isolate
  /// and sends them to the worker. This is required because Flutter's asset
  /// binding (rootBundle / Interpreter.fromAsset) is only available on the
  /// main isolate — calling it from a spawned isolate throws silently.
  Future<void> _initInferenceIsolate() async {
    try {
      final receivePort = ReceivePort();
      _inferenceIsolate = await Isolate.spawn(_inferenceWorker, receivePort.sendPort);

      // First message from the isolate is its own SendPort
      _isolateSendPort = await receivePort.first as SendPort;

      // Load model bytes on the main isolate where rootBundle is available
      final modelData = await rootBundle.load('assets/models/movenet_thunder.tflite');
      final modelBytes = modelData.buffer.asUint8List();

      // Send model bytes to the isolate so it can build the Interpreter
      _isolateSendPort!.send(modelBytes);

      _isolateReady = true;
      debugPrint('[Isolate] Inference isolate ready, model bytes sent (${modelBytes.length} bytes)');
    } catch (e) {
      debugPrint('[Isolate] Failed to init inference isolate: $e');
    }
  }

  Future<void> _initCamera([
    CameraLensDirection direction = CameraLensDirection.back,
  ]) async {
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

      await _cameraController!.startImageStream((image) {
        if (!_isolateReady || _isProcessingFrame) return;

        // Only run inference while the user is actively holding a pose.
        final status = ref.read(workoutSessionProvider).value?.status;
        if (status != WorkoutStatus.active) return;

        final now = DateTime.now();
        if (now.difference(_lastFrameTime).inMilliseconds < _minFrameIntervalMs) return;
        _lastFrameTime = now;
        _isProcessingFrame = true;
        _sendFrameToIsolate(image);
      });
    } catch (e) {
      debugPrint('[Camera] Init error: $e');
    }
  }

  Future<void> _toggleCamera() async {
    await _initCamera(
      _isFrontCamera ? CameraLensDirection.back : CameraLensDirection.front,
    );
  }

  // ── Isolate-based inference ───────────────────────────────────────────────
  // Raw camera planes are sent to the isolate — zero pixel work on UI thread.
  // The isolate does YUV/BGRA conversion + TFLite inference + mirror correction.

  void _sendFrameToIsolate(CameraImage image) {
    try {
      final replyPort = ReceivePort();
      replyPort.listen((message) {
        replyPort.close();
        if (message is _FrameResult && mounted) {
          _handleInferenceResult(message);
        }
        _isProcessingFrame = false;
      });

      final bool isYuv = Platform.isAndroid &&
          image.format.group == ImageFormatGroup.yuv420;
      final bool isBgra = image.format.group == ImageFormatGroup.bgra8888;

      if (!isYuv && !isBgra) {
        replyPort.close();
        _isProcessingFrame = false;
        return;
      }

      // Copy plane bytes — required because CameraImage buffers are reused
      final plane0 = Uint8List.fromList(image.planes[0].bytes);
      final plane1 = isYuv ? Uint8List.fromList(image.planes[1].bytes) : null;
      final plane2 = isYuv ? Uint8List.fromList(image.planes[2].bytes) : null;

      _isolateSendPort!.send(_FrameRequest(
        replyPort: replyPort.sendPort,
        plane0: plane0,
        plane1: plane1,
        plane2: plane2,
        plane0RowStride: image.planes[0].bytesPerRow,
        plane1RowStride: isYuv ? image.planes[1].bytesPerRow : 0,
        plane1PixelStride: isYuv ? (image.planes[1].bytesPerPixel ?? 2) : 2,
        srcWidth: image.width,
        srcHeight: image.height,
        isYuv: isYuv,
        isFront: _isFrontCamera,
        sensorOrientation: _cameraController!.description.sensorOrientation,
      ));
    } catch (e) {
      debugPrint('[Inference] Send error: $e');
      _isProcessingFrame = false;
    }
  }

  void _handleInferenceResult(_FrameResult result) {
    final keypoints = <KeypointType, Keypoint>{};
    for (int i = 0; i < 17 && i < result.keypoints.length; i++) {
      final kp = result.keypoints[i];
      keypoints[KeypointType.values[i]] = Keypoint(x: kp[0], y: kp[1], score: kp[2]);
    }
    final pose = Pose(keypoints);
    setState(() => _currentPose = pose);

    final sessionValue = ref.read(workoutSessionProvider).value;
    if (sessionValue?.status == WorkoutStatus.active) {
      final currentAsana = sessionValue?.currentAsana;
      if (currentAsana != null) {
        _poseAnalyzer!.processRawPose(pose, currentAsana);
      }
    }
  }

  // ── Master timer (drift-correcting) ──────────────────────────────────────
  // Uses a Stopwatch to detect how many seconds have actually elapsed since
  // the last tick. If inference blocked the event loop and caused a skipped
  // tick, we fire the notifier the correct number of times to catch up.
  // This guarantees the countdown never freezes even under heavy CPU load.

  void _startMasterTimer() {
    _masterTimer?.cancel();
    _timerStopwatch
      ..reset()
      ..start();
    _lastTickMs = 0;

    _masterTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;

      final elapsedMs = _timerStopwatch.elapsedMilliseconds;
      final secondsElapsed = (elapsedMs - _lastTickMs) ~/ 1000;
      if (secondsElapsed <= 0) return;

      _lastTickMs += secondsElapsed * 1000;

      final notifier = ref.read(workoutSessionProvider.notifier);
      final status = ref.read(workoutSessionProvider).value?.status;

      // Fire the correct number of ticks to compensate for any skipped seconds
      for (int i = 0; i < secondsElapsed; i++) {
        switch (status) {
          case WorkoutStatus.active:
            notifier.tick();
            notifier.tickAsana();
          case WorkoutStatus.rest:
            notifier.tick();
            notifier.tickRest();
          case WorkoutStatus.preview:
            notifier.tickPreview();
          default:
            break;
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _masterTimer?.cancel();
      _timerStopwatch.stop();
      _cameraController?.stopImageStream().catchError((_) {});
      _cameraController?.dispose();
    } else if (state == AppLifecycleState.paused) {
      _masterTimer?.cancel();
      _timerStopwatch.stop();
      ref.read(workoutSessionProvider.notifier).handleAppBackground();
    } else if (state == AppLifecycleState.resumed) {
      // Reset stopwatch so we don't fire a burst of ticks for time spent in background
      _timerStopwatch
        ..reset()
        ..start();
      _lastTickMs = 0;
      _startMasterTimer();
      if (_cameraController != null && !_cameraController!.value.isInitialized) {
        _initCamera(_isFrontCamera ? CameraLensDirection.front : CameraLensDirection.back);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _masterTimer?.cancel();
    _timerStopwatch.stop();
    _cameraController?.dispose();
    _poseAnalyzer?.dispose();
    // Shut down the inference isolate cleanly
    _isolateSendPort?.send('dispose');
    _inferenceIsolate?.kill(priority: Isolate.immediate);
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
      backgroundColor: Colors.black,
      body: sessionAsync.when(
        data: (s) => _buildBody(s),
        loading: () => const Center(child: CircularProgressIndicator(color: Colors.white)),
        error: (e, _) => Center(
          child: Text(e.toString(), style: const TextStyle(color: Colors.white)),
        ),
      ),
    );
  }

  Widget _buildBody(WorkoutSessionState session) {
    if (session.status == WorkoutStatus.completed) {
      return _CompletedView(
        elapsedSeconds: session.elapsedSeconds,
        totalAsanas: session.asanas.length,
        posesCompleted: session.posesCompleted,
        calories: session.estimatedCalories,
        averageAccuracy: session.averageAccuracy,
        onDone: () => Navigator.of(context).pop(),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Layer 1: Camera + skeleton overlay
        // Only show the skeleton while actively holding a pose — clear it during
        // rest, preview, and paused states so the frozen skeleton doesn't linger.
        _CameraLayer(
          controller: _cameraController,
          isReady: _cameraReady,
          pose: session.status == WorkoutStatus.active ? _currentPose : null,
        ),

        // Layer 2: Top HUD (Task 5: reduced opacity gradient)
        SafeArea(
          child: _TopHud(session: session, onPauseExit: _onPauseExit),
        ),

        // Layer 3: Bottom controls
        Positioned(
          bottom: 32,
          left: 16,
          right: 16,
          child: SafeArea(
            child: _BottomControls(
              session: session,
              onPauseResume: () {
                if (session.status == WorkoutStatus.active ||
                    session.status == WorkoutStatus.preview) {
                  _masterTimer?.cancel();
                  ref.read(workoutSessionProvider.notifier).pause();
                } else if (session.status == WorkoutStatus.paused) {
                  ref.read(workoutSessionProvider.notifier).resume();
                  _startMasterTimer();
                }
              },
              onNext: () => ref.read(workoutSessionProvider.notifier).nextAsana(),
            ),
          ),
        ),

        // Layer 4: Camera flip FAB
        if (_cameraReady)
          Positioned(
            bottom: 110,
            right: 20,
            child: SafeArea(
              child: GestureDetector(
                onTap: _toggleCamera,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.45),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withOpacity(0.25)),
                  ),
                  child: const Icon(Icons.flip_camera_ios_rounded, color: Colors.white, size: 22),
                ),
              ),
            ),
          ),

        // Layer 5: Rest overlay
        if (session.status == WorkoutStatus.rest)
          _RestOverlay(
            session: session,
            onExtend: () => ref.read(workoutSessionProvider.notifier).extendRest(),
            onSkip: () => ref.read(workoutSessionProvider.notifier).nextAsana(),
          ),

        // Layer 6: Pre-pose preview overlay (Task 2)
        if (session.status == WorkoutStatus.preview)
          _PreviewOverlay(session: session),
      ],
    );
  }
}

// ── Camera Layer ──────────────────────────────────────────────────────────────

class _CameraLayer extends StatelessWidget {
  const _CameraLayer({required this.controller, required this.isReady, required this.pose});
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
              Icon(Icons.videocam_off_outlined, size: 56, color: Colors.white.withOpacity(0.15)),
              const SizedBox(height: 12),
              Text(
                'Camera unavailable\nPose detection requires a physical device',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(color: Colors.white.withOpacity(0.25), fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(
          controller!,
          child: pose != null
              ? CustomPaint(
                  painter: SkeletonPainter(pose: pose!),
                  child: const SizedBox.expand(),
                )
              : null,
        ),
      ],
    );
  }
}

// ── Top HUD (Task 5: reduced gradient opacity) ────────────────────────────────

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
        // Task 5: reduced from 0.75 to 0.40 — camera stays visible
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withOpacity(0.40), Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: GoogleFonts.inter(
                            fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white)),
                    if (sanskrit.isNotEmpty)
                      Text(sanskrit,
                          style: GoogleFonts.inter(
                              fontSize: 13, color: Colors.white54, fontStyle: FontStyle.italic)),
                    const SizedBox(height: 4),
                    Text(
                      'Pose ${session.currentAsanaIndex + 1} of ${session.asanas.length}',
                      style: GoogleFonts.inter(fontSize: 12, color: Colors.white54),
                    ),
                    const SizedBox(height: 8),
                    if (session.status == WorkoutStatus.active)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: session.currentAccuracy > 80 ? Colors.green.withOpacity(0.2) : session.currentAccuracy > 60 ? Colors.orange.withOpacity(0.2) : Colors.red.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: session.currentAccuracy > 80 ? Colors.green : session.currentAccuracy > 60 ? Colors.orange : Colors.red,
                          ),
                        ),
                        child: Text(
                          'Accuracy: ${session.currentAccuracy.toStringAsFixed(0)}%',
                          style: GoogleFonts.inter(
                            color: session.currentAccuracy > 80 ? Colors.greenAccent : session.currentAccuracy > 60 ? Colors.orangeAccent : Colors.redAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _CountdownRing(
                    progress: progress,
                    label: _fmtTime(session.asanaCountdownSeconds),
                    size: 72,
                    color: const Color(0xFF00E5FF),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.timer_outlined, color: Colors.white54, size: 13),
                      const SizedBox(width: 4),
                      Text(_fmtTime(session.elapsedSeconds),
                          style: GoogleFonts.inter(fontSize: 12, color: Colors.white54)),
                    ],
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white, size: 22),
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
          Text(label,
              style: GoogleFonts.inter(
                  fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
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
            icon: isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
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
          border: Border.all(color: Colors.white.withOpacity(0.2), width: 0.8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(label,
                style: GoogleFonts.inter(
                    color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15)),
          ],
        ),
      ),
    );
  }
}

// ── Task 2: Pre-Pose Preview Overlay ─────────────────────────────────────────

class _PreviewOverlay extends StatelessWidget {
  const _PreviewOverlay({required this.session});
  final WorkoutSessionState session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final asana = session.currentAsana;
    final name = asana?['english_name'] as String? ?? 'Get Ready';
    final sanskrit = asana?['sanskrit_name'] as String? ?? '';
    final description = asana?['description'] as String? ?? '';
    final orientation = asana?['preferred_orientation'] as String? ?? 'front';
    final isFirst = session.currentAsanaIndex == 0 && session.posesCompleted == 0;
    final countdown = session.previewCountdown;

    return Container(
      color: Colors.black.withOpacity(0.88),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: theme.colorScheme.primary.withOpacity(0.5)),
                ),
                child: Text(
                  isFirst ? 'STARTING WORKOUT' : 'NEXT POSE',
                  style: GoogleFonts.inter(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 3,
                    fontSize: 12,
                  ),
                ),
              ),

              const SizedBox(height: 28),

              // Pose Image
              Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(0.12),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.colorScheme.primary.withOpacity(0.35),
                    width: 3,
                  ),
                ),
                child: ClipOval(
                  child: asana != null && asana['id'] != null
                      ? Image.asset(
                          'assets/images/poses/${asana['id']}.jpeg',
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => Icon(
                            Icons.self_improvement_rounded,
                            size: 64,
                            color: theme.colorScheme.primary,
                          ),
                        )
                      : Icon(
                          Icons.self_improvement_rounded,
                          size: 64,
                          color: theme.colorScheme.primary,
                        ),
                ),
              ),

              const SizedBox(height: 24),

              // Pose name
              Text(
                name,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              if (sanskrit.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  sanskrit,
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    color: Colors.white54,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],

              if (description.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  description,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(fontSize: 13, color: Colors.white38),
                ),
              ],

              const SizedBox(height: 20),
              
              // Direction indicator
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: theme.colorScheme.primary.withOpacity(0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      orientation == 'side' ? Icons.screen_rotation_rounded : Icons.person_rounded,
                      color: theme.colorScheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      orientation == 'side' ? 'Face Sideways' : 'Face Forward',
                      style: GoogleFonts.inter(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 36),

              // Get Ready label
              Text(
                'Get Ready',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  color: Colors.white54,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 12),

              // Big countdown number
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (child, anim) => ScaleTransition(scale: anim, child: child),
                child: Text(
                  '$countdown',
                  key: ValueKey(countdown),
                  style: GoogleFonts.inter(
                    fontSize: 80,
                    fontWeight: FontWeight.w900,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),

              const SizedBox(height: 8),
              Text(
                'Pose ${session.currentAsanaIndex + 1} of ${session.asanas.length}',
                style: GoogleFonts.inter(fontSize: 13, color: Colors.white38),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Rest Overlay ──────────────────────────────────────────────────────────────

class _RestOverlay extends StatelessWidget {
  const _RestOverlay({required this.session, required this.onExtend, required this.onSkip});
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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: theme.colorScheme.primary.withOpacity(0.5)),
                ),
                child: Text('REST',
                    style: GoogleFonts.inter(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 3,
                        fontSize: 13)),
              ),
              const SizedBox(height: 28),
              _CountdownRing(
                progress: progress,
                label: remaining.toString(),
                size: 140,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 8),
              Text('seconds remaining',
                  style: GoogleFonts.inter(color: Colors.white54, fontSize: 14)),
              const SizedBox(height: 36),
              if (next != null) ...[
                Text('COMING UP',
                    style: GoogleFonts.inter(
                        color: Colors.white38, fontSize: 11, letterSpacing: 2,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.12)),
                  ),
                  child: Row(
                    children: [
                      if (next['id'] != null)
                        Container(
                          width: 60,
                          height: 60,
                          margin: const EdgeInsets.only(right: 16),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: theme.colorScheme.primary.withOpacity(0.3),
                              width: 2,
                            ),
                          ),
                          child: ClipOval(
                            child: Image.asset(
                              'assets/images/poses/${next['id']}.jpeg',
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) => Icon(
                                Icons.self_improvement_rounded,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(next['english_name'] as String? ?? '',
                                style: GoogleFonts.inter(
                                    color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                            if ((next['sanskrit_name'] as String?)?.isNotEmpty ?? false)
                              Text(next['sanskrit_name'] as String,
                                  style: GoogleFonts.inter(
                                      color: Colors.white38, fontSize: 13, fontStyle: FontStyle.italic)),
                            const SizedBox(height: 6),
                            Text('${(next['duration_seconds'] as int?) ?? 60}s hold',
                                style: GoogleFonts.inter(
                                    color: theme.colorScheme.primary, fontSize: 13,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: session.canExtendRest ? onExtend : null,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(
                            color: session.canExtendRest
                                ? theme.colorScheme.primary
                                : Colors.white24),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
                            fontSize: 14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: onSkip,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: Text('Skip',
                        style: GoogleFonts.inter(
                            color: Colors.white54, fontWeight: FontWeight.w600)),
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
    required this.posesCompleted,
    required this.calories,
    required this.averageAccuracy,
    required this.onDone,
  });
  final int elapsedSeconds;
  final int totalAsanas;
  final int posesCompleted;
  final int calories;
  final double averageAccuracy;
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
                        color: theme.colorScheme.primary.withOpacity(0.4), width: 2),
                  ),
                  child: Icon(Icons.self_improvement_rounded,
                      size: 64, color: theme.colorScheme.primary),
                ),
                const SizedBox(height: 28),
                Text('Session Complete!',
                    style: GoogleFonts.inter(
                        fontSize: 28, fontWeight: FontWeight.w800, color: Colors.white)),
                const SizedBox(height: 8),
                Text('Outstanding work. Keep the flow going.',
                    style: GoogleFonts.inter(fontSize: 15, color: Colors.white54)),
                const SizedBox(height: 32),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _StatChip(label: 'Duration', value: _fmtTime(elapsedSeconds)),
                    const SizedBox(width: 12),
                    _StatChip(label: 'Poses', value: '$posesCompleted/$totalAsanas'),
                    const SizedBox(width: 12),
                    _StatChip(label: 'Accuracy', value: '${averageAccuracy.toStringAsFixed(0)}%'),
                  ],
                ),
                const SizedBox(height: 40),
                FilledButton(
                  onPressed: onDone,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  ),
                  child: Text('Done',
                      style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w700)),
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
  const _StatChip({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
      ),
      child: Column(
        children: [
          Text(value,
              style: GoogleFonts.inter(
                  fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
          const SizedBox(height: 2),
          Text(label,
              style: GoogleFonts.inter(fontSize: 10, color: Colors.white38)),
        ],
      ),
    );
  }
}

// _kMaxRestExtensions is defined in workout_session_provider.dart and imported via the provider import.
