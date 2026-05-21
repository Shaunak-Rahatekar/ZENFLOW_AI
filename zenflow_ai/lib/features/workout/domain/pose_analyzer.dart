import 'dart:async';
import 'package:zenflow_ai/features/workout/models/pose.dart';
import 'package:zenflow_ai/features/workout/utils/math_utils.dart';

class CorrectionData {
  final String jointName;
  final String englishFeedback;
  final String marathiFeedback;
  
  CorrectionData(this.jointName, this.englishFeedback, this.marathiFeedback);
}

class PoseAnalyzer {
  // Smoothing configuration
  final double emaAlpha = 0.3;
  Pose? _previousSmoothedPose;

  // Throttling configuration
  DateTime _lastAnalysisTime = DateTime.fromMillisecondsSinceEpoch(0);
  final int throttleMs = 66; // ~15 FPS (1000ms / 15)

  // Persistence tracking for "Wrong Posture"
  final Map<String, DateTime> _outOfBoundsTimers = {};
  final Duration persistenceThreshold = const Duration(seconds: 2);

  // Callbacks
  final void Function(CorrectionData)? onCorrectionNeeded;

  PoseAnalyzer({this.onCorrectionNeeded});

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

    // Analyze angles against target asana
    _analyzePose(smoothedPose, targetAsana, now);
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
      
      smoothedKeypoints[type] = Keypoint(x: smoothedX, y: smoothedY, score: rawPt.score);
    }

    return Pose(smoothedKeypoints);
  }

  void _analyzePose(Pose pose, Map<String, dynamic> targetAsana, DateTime now) {
    final idealAngles = targetAsana['ideal_angles'] as Map<String, dynamic>? ?? {};
    final corrections = targetAsana['corrections'] as Map<String, dynamic>? ?? {};

    // Helper to get angle for specific joints mapping string names to keypoint triplets
    final angleCalculations = <String, double?>{
      'left_knee': _getAngle(pose, KeypointType.leftHip, KeypointType.leftKnee, KeypointType.leftAnkle),
      'right_knee': _getAngle(pose, KeypointType.rightHip, KeypointType.rightKnee, KeypointType.rightAnkle),
      'left_hip': _getAngle(pose, KeypointType.leftShoulder, KeypointType.leftHip, KeypointType.leftKnee),
      'right_hip': _getAngle(pose, KeypointType.rightShoulder, KeypointType.rightHip, KeypointType.rightKnee),
      'left_elbow': _getAngle(pose, KeypointType.leftShoulder, KeypointType.leftElbow, KeypointType.leftWrist),
      'right_elbow': _getAngle(pose, KeypointType.rightShoulder, KeypointType.rightElbow, KeypointType.rightWrist),
    };

    for (final entry in idealAngles.entries) {
      final jointName = entry.key;
      final thresholds = entry.value;
      
      final currentAngle = angleCalculations[jointName];
      if (currentAngle == null) continue;

      final minAngle = (thresholds['min'] as num).toDouble();
      final maxAngle = (thresholds['max'] as num).toDouble();

      if (currentAngle < minAngle || currentAngle > maxAngle) {
        // Out of bounds
        if (!_outOfBoundsTimers.containsKey(jointName)) {
          _outOfBoundsTimers[jointName] = now;
        } else {
          final timeOutOfBounds = now.difference(_outOfBoundsTimers[jointName]!);
          if (timeOutOfBounds >= persistenceThreshold) {
            // Trigger callback
            _triggerCorrection(jointName, corrections);
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

    // Check confidence scores (e.g. > 0.3)
    if (ptA == null || ptB == null || ptC == null) return null;
    if (ptA.score < 0.3 || ptB.score < 0.3 || ptC.score < 0.3) return null;

    return MathUtils.calculateAngle(ptA.x, ptA.y, ptB.x, ptB.y, ptC.x, ptC.y);
  }

  void _triggerCorrection(String jointName, Map<String, dynamic> corrections) {
    if (onCorrectionNeeded == null) return;

    // Find a relevant correction phrase (simplified matching for MVP)
    String matchedKey = corrections.keys.firstWhere(
      (k) => k.contains(jointName.split('_').last) || k.contains(jointName), 
      orElse: () => ''
    );

    if (matchedKey.isNotEmpty) {
      final correction = corrections[matchedKey];
      onCorrectionNeeded!(CorrectionData(
        jointName,
        correction['english'] ?? '',
        correction['marathi'] ?? ''
      ));
    } else {
       // Fallback generic message
       onCorrectionNeeded!(CorrectionData(
        jointName,
        'Please adjust your $jointName.',
        'कृपया आपला $jointName तपासा.'
      ));
    }
  }
}
