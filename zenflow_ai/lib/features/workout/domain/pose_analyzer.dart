import 'dart:math' as math;
import 'package:zenflow_ai/features/workout/models/pose.dart';
import 'package:zenflow_ai/features/workout/utils/math_utils.dart';

class CorrectionData {
  final String jointName;
  final String englishFeedback;
  final String marathiFeedback;

  CorrectionData(this.jointName, this.englishFeedback, this.marathiFeedback);
}

class PoseAnalyzer {
  final String healthConditions;

  // Smoothing configuration
  final double emaAlpha = 0.15;
  Pose? _previousSmoothedPose;

  // Throttling configuration
  DateTime _lastAnalysisTime = DateTime.fromMillisecondsSinceEpoch(0);
  final int throttleMs = 66; // ~15 FPS (1000ms / 15)

  // Persistence tracking for "Wrong Posture"
  final Map<String, DateTime> _outOfBoundsTimers = {};
  final Duration persistenceThreshold = const Duration(seconds: 3);

  // Motivation tracking
  DateTime _lastCorrectionTime = DateTime.now();
  final Duration motivationThreshold = const Duration(seconds: 15);
  DateTime _lastVisibilityWarning = DateTime.fromMillisecondsSinceEpoch(0);
  double _lastCalculatedAccuracy = 0.0;

  // Callbacks
  final void Function(CorrectionData)? onCorrectionNeeded;
  final void Function()? onMotivationNeeded;
  final void Function(double accuracy)? onAccuracyUpdate;

  PoseAnalyzer({
    this.healthConditions = '',
    this.onCorrectionNeeded,
    this.onMotivationNeeded,
    this.onAccuracyUpdate,
  });

  /// Processes raw keypoints from the camera stream
  void processRawPose(Pose rawPose, Map<String, dynamic> targetAsana) {
    final now = DateTime.now();

    // Throttle to ~15 FPS
    if (now.difference(_lastAnalysisTime).inMilliseconds < throttleMs) {
      return;
    }
    _lastAnalysisTime = now;

    // Apply EMA Smoothing
    final smoothedPose = _applyEmaSmoothing(rawPose);
    _previousSmoothedPose = smoothedPose;

    // Global Visibility Check
    if (!_isGloballyVisible(smoothedPose)) {
      _outOfBoundsTimers.clear(); // Pause timers while out of frame
      if (now.difference(_lastVisibilityWarning) >= const Duration(seconds: 15)) {
        if (onCorrectionNeeded != null) {
          onCorrectionNeeded!(CorrectionData(
            'visibility', 
            'I cannot see your full body. Please step back.', 
            'मला तुमचे पूर्ण शरीर दिसत नाही. कृपया थोडे मागे जा.'
          ));
        }
        _lastVisibilityWarning = now;
      }
      return; // Skip angle analysis if not fully visible
    }

    // Calculate Similarity Accuracy
    _calculateSimilarity(smoothedPose, targetAsana);

    // Analyze angles against target asana
    _analyzePose(smoothedPose, targetAsana, now);
    
    // Check for motivation trigger
    if (_outOfBoundsTimers.isEmpty && _lastCalculatedAccuracy > 70.0 && now.difference(_lastCorrectionTime) >= motivationThreshold) {
      if (onMotivationNeeded != null) {
        onMotivationNeeded!();
        _lastCorrectionTime = now; // reset to avoid spamming
      }
    }
  }

  Pose _applyEmaSmoothing(Pose rawPose) {
    if (_previousSmoothedPose == null) return rawPose;

    final smoothedKeypoints = <KeypointType, Keypoint>{};

    for (var type in KeypointType.values) {
      final rawPt = rawPose.keypoints[type];
      final prevPt = _previousSmoothedPose!.keypoints[type];

      if (rawPt == null) continue;

      if (prevPt == null) {
        smoothedKeypoints[type] = rawPt;
        continue;
      }

      final smoothedX = (emaAlpha * rawPt.x) + ((1 - emaAlpha) * prevPt.x);
      final smoothedY = (emaAlpha * rawPt.y) + ((1 - emaAlpha) * prevPt.y);

      smoothedKeypoints[type] = Keypoint(
        x: smoothedX,
        y: smoothedY,
        score: rawPt.score,
      );
    }

    return Pose(smoothedKeypoints);
  }

  bool _isGloballyVisible(Pose pose) {
    // Check if shoulders and hips are visible (confidence > 0.45)
    final leftShoulder = pose.keypoints[KeypointType.leftShoulder];
    final rightShoulder = pose.keypoints[KeypointType.rightShoulder];
    final leftHip = pose.keypoints[KeypointType.leftHip];
    final rightHip = pose.keypoints[KeypointType.rightHip];

    if (leftShoulder == null || rightShoulder == null || leftHip == null || rightHip == null) return false;
    // Lowered threshold to 0.25 to prevent false 'step back' warnings when wearing loose clothing or sitting.
    if (leftShoulder.score < 0.25 || rightShoulder.score < 0.25 || leftHip.score < 0.25 || rightHip.score < 0.25) return false;

    return true;
  }

  void _calculateSimilarity(Pose pose, Map<String, dynamic> targetAsana) {
    if (onAccuracyUpdate == null) return;
    final targetSkeleton = targetAsana['target_skeleton'] as List<dynamic>?;
    if (targetSkeleton == null || targetSkeleton.length != 34) return;

    // Normalize current pose
    final validPts = pose.keypoints.values.where((k) => k.score > 0.45).toList();
    if (validPts.isEmpty) return;

    double minX = validPts.map((k) => k.x).reduce((a, b) => a < b ? a : b);
    double maxX = validPts.map((k) => k.x).reduce((a, b) => a > b ? a : b);
    double minY = validPts.map((k) => k.y).reduce((a, b) => a < b ? a : b);
    double maxY = validPts.map((k) => k.y).reduce((a, b) => a > b ? a : b);

    final cx = (minX + maxX) / 2;
    final cy = (minY + maxY) / 2;
    double size = (maxX - minX) > (maxY - minY) ? (maxX - minX) : (maxY - minY);
    if (size == 0) size = 1;

    final currentVector = List<double>.filled(34, 0);
    for (int i = 0; i < 17; i++) {
      final type = KeypointType.values[i];
      final kp = pose.keypoints[type];
      if (kp != null && kp.score > 0.45) {
        currentVector[i * 2] = (kp.x - cx) / size;
        currentVector[i * 2 + 1] = (kp.y - cy) / size;
      }
    }

    // Cosine similarity
    double dotProduct = 0;
    double normA = 0;
    double normB = 0;
    for (int i = 0; i < 34; i++) {
      final a = currentVector[i];
      final b = (targetSkeleton[i] as num).toDouble();
      dotProduct += a * b;
      normA += a * a;
      normB += b * b;
    }

    if (normA == 0 || normB == 0) return;
    
    // Calculate raw cosine similarity [-1, 1]
    final similarity = dotProduct / (math.sqrt(normA) * math.sqrt(normB));
    
    // Convert to percentage. Due to perspective shifts, 0.90 is often visually perfect.
    // Scale 0.75 to 0.90 -> 0 to 100%
    double percentage = ((similarity - 0.75) / 0.15) * 100;
    if (percentage > 100) percentage = 100;
    if (percentage < 0) percentage = 0;
    
    _lastCalculatedAccuracy = percentage;
    onAccuracyUpdate!(percentage);
  }

  void _analyzePose(Pose pose, Map<String, dynamic> targetAsana, DateTime now) {
    final idealAngles =
        targetAsana['ideal_angles'] as Map<String, dynamic>? ?? {};
    final corrections =
        targetAsana['corrections'] as Map<String, dynamic>? ?? {};

    // Helper to get angle for specific joints mapping string names to keypoint triplets
    final angleCalculations = <String, double?>{
      'left_knee': _getAngle(
        pose,
        KeypointType.leftHip,
        KeypointType.leftKnee,
        KeypointType.leftAnkle,
      ),
      'right_knee': _getAngle(
        pose,
        KeypointType.rightHip,
        KeypointType.rightKnee,
        KeypointType.rightAnkle,
      ),
      'left_hip': _getAngle(
        pose,
        KeypointType.leftShoulder,
        KeypointType.leftHip,
        KeypointType.leftKnee,
      ),
      'right_hip': _getAngle(
        pose,
        KeypointType.rightShoulder,
        KeypointType.rightHip,
        KeypointType.rightKnee,
      ),
      'left_elbow': _getAngle(
        pose,
        KeypointType.leftShoulder,
        KeypointType.leftElbow,
        KeypointType.leftWrist,
      ),
      'right_elbow': _getAngle(
        pose,
        KeypointType.rightShoulder,
        KeypointType.rightElbow,
        KeypointType.rightWrist,
      ),
    };

    for (final entry in idealAngles.entries) {
      final jointName = entry.key;
      final thresholds = entry.value;

      final currentAngle = angleCalculations[jointName];
      if (currentAngle == null) continue;

      double minAngle = (thresholds['min'] as num).toDouble();
      final maxAngle = (thresholds['max'] as num).toDouble();

      bool isSafetyAlert = false;
      String safetyCondition = '';

      final hcLower = healthConditions.toLowerCase();
      if ((hcLower.contains('back pain') || hcLower.contains('lower back pain')) &&
          (jointName == 'left_hip' || jointName == 'right_hip')) {
        if (minAngle < 100.0) {
          minAngle = 100.0;
        }
        if (currentAngle < 100.0) {
          isSafetyAlert = true;
          safetyCondition = 'back pain';
        }
      }

      if ((hcLower.contains('knee pain') || hcLower.contains('arthritis')) &&
          (jointName == 'left_knee' || jointName == 'right_knee')) {
        if (minAngle < 100.0) {
          minAngle = 100.0;
        }
        if (currentAngle < 100.0) {
          isSafetyAlert = true;
          safetyCondition = 'knee pain';
        }
      }

      // Add a 25-degree tolerance so human bodies aren't judged as perfect protractors
      // 2D tracking can easily be off by 20 degrees due to depth distortion.
      bool isOutOfTolerance = currentAngle < (minAngle - 25) || currentAngle > (maxAngle + 25);
      if (isSafetyAlert) isOutOfTolerance = true; // Safety alerts bypass tolerance

      if (isOutOfTolerance) {
        final isTooBent = currentAngle < minAngle;

        // Out of bounds
        if (!_outOfBoundsTimers.containsKey(jointName)) {
          _outOfBoundsTimers[jointName] = now;
        } else {
          final timeOutOfBounds = now.difference(
            _outOfBoundsTimers[jointName]!,
          );
          if (timeOutOfBounds >= persistenceThreshold) {
            // Global cooldown: ensure we don't spam multiple corrections across different joints
            if (now.difference(_lastCorrectionTime) > const Duration(seconds: 10)) {
              // Trigger callback
              _triggerCorrection(jointName, corrections, isTooBent, isSafetyAlert, safetyCondition);
              _lastCorrectionTime = now;
            }
            // Reset timer so we don't spam
            _outOfBoundsTimers.remove(jointName);
          }
        }
      } else {
        // Back in bounds, reset timer
        _outOfBoundsTimers.remove(jointName);
      }
    }
  }

  double? _getAngle(Pose pose, KeypointType a, KeypointType b, KeypointType c) {
    final ptA = pose.keypoints[a];
    final ptB = pose.keypoints[b]; // Vertex
    final ptC = pose.keypoints[c];

    // Check confidence scores — use 0.65 for stricter filtering to avoid noisy false positives
    if (ptA == null || ptB == null || ptC == null) return null;
    if (ptA.score < 0.65 || ptB.score < 0.65 || ptC.score < 0.65) return null;

    return MathUtils.calculateAngle(ptA.x, ptA.y, ptB.x, ptB.y, ptC.x, ptC.y);
  }

  void _triggerCorrection(
      String jointName, Map<String, dynamic> corrections, bool isTooBent, bool isSafetyAlert, String safetyCondition) {
    if (onCorrectionNeeded == null) return;

    if (isSafetyAlert) {
      onCorrectionNeeded!(
        CorrectionData(
          jointName,
          'It isn\'t safe for you due to your $safetyCondition, don\'t bend too much.',
          'तुमच्या $safetyCondition मुळे हे सुरक्षित नाही, जास्त वाकू नका.',
        ),
      );
      return;
    }

    // Determine directional key (e.g. left_knee_bent or left_knee_overextended)
    final directionSuffix = isTooBent ? 'bent' : 'overextended';
    final targetKey = '${jointName}_$directionSuffix';

    String matchedKey = corrections.keys.firstWhere(
      (k) => k == targetKey || k.contains(targetKey),
      orElse: () => '',
    );

    // Fallback to just the joint name if specific direction isn't found
    if (matchedKey.isEmpty) {
      matchedKey = corrections.keys.firstWhere(
        (k) => k.contains(jointName.split('_').last) || k.contains(jointName),
        orElse: () => '',
      );
    }

    if (matchedKey.isNotEmpty && corrections[matchedKey] != null) {
      final correction = corrections[matchedKey];
      onCorrectionNeeded!(
        CorrectionData(
          jointName,
          correction['english'] ?? '',
          correction['marathi'] ?? '',
        ),
      );
    } else {
      final readableJoint = jointName.replaceAll('_', ' ');
      final dynamicAction = isTooBent ? 'straighten' : 'bend';
      final marathiAction = isTooBent ? 'सरळ करा' : 'वाकवा';

      final friendlyPrefixes = [
        'Try to',
        'See if you can',
        'You\'re doing great, just',
        'Almost there, please'
      ];
      friendlyPrefixes.shuffle();
      final prefix = friendlyPrefixes.first;

      onCorrectionNeeded!(
        CorrectionData(
          jointName,
          '$prefix $dynamicAction your $readableJoint a little bit.',
          'कृपया तुमचा $readableJoint थोडा $marathiAction.',
        ),
      );
    }
  }

  void dispose() {
    _outOfBoundsTimers.clear();
    _previousSmoothedPose = null;
  }
}
