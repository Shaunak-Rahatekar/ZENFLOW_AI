import 'package:flutter/material.dart';
import 'package:zenflow_ai/features/workout/models/pose.dart';

// Skeleton connectivity: pairs of KeypointType that form bones
const List<(KeypointType, KeypointType)> _kBones = [
  // Head
  (KeypointType.nose, KeypointType.leftEye),
  (KeypointType.nose, KeypointType.rightEye),
  (KeypointType.leftEye, KeypointType.leftEar),
  (KeypointType.rightEye, KeypointType.rightEar),
  // Torso
  (KeypointType.leftShoulder, KeypointType.rightShoulder),
  (KeypointType.leftShoulder, KeypointType.leftHip),
  (KeypointType.rightShoulder, KeypointType.rightHip),
  (KeypointType.leftHip, KeypointType.rightHip),
  // Arms
  (KeypointType.leftShoulder, KeypointType.leftElbow),
  (KeypointType.leftElbow, KeypointType.leftWrist),
  (KeypointType.rightShoulder, KeypointType.rightElbow),
  (KeypointType.rightElbow, KeypointType.rightWrist),
  // Legs
  (KeypointType.leftHip, KeypointType.leftKnee),
  (KeypointType.leftKnee, KeypointType.leftAnkle),
  (KeypointType.rightHip, KeypointType.rightKnee),
  (KeypointType.rightKnee, KeypointType.rightAnkle),
];

/// Custom painter that draws the human skeleton over the camera preview.
class SkeletonPainter extends CustomPainter {
  final Pose pose;

  const SkeletonPainter({required this.pose});

  @override
  void paint(Canvas canvas, Size size) {
    final bonePaint = Paint()
      ..color = const Color(0xCC00E5FF)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Draw bones — use 0.2 threshold so skeleton appears even at moderate confidence
    for (final (a, b) in _kBones) {
      final ptA = pose.keypoints[a];
      final ptB = pose.keypoints[b];
      if (ptA == null || ptB == null) continue;
      if (ptA.score < 0.45 || ptB.score < 0.45) continue;

      canvas.drawLine(
        Offset(ptA.x * size.width, ptA.y * size.height),
        Offset(ptB.x * size.width, ptB.y * size.height),
        bonePaint,
      );
    }

    // Draw keypoint dots
    for (final entry in pose.keypoints.entries) {
      final kp = entry.value;
      if (kp.score < 0.45) continue;

      final color = _colorForScore(kp.score);
      canvas.drawCircle(
        Offset(kp.x * size.width, kp.y * size.height),
        5.0,
        Paint()..color = color..style = PaintingStyle.fill,
      );
      // White ring
      canvas.drawCircle(
        Offset(kp.x * size.width, kp.y * size.height),
        5.0,
        Paint()
          ..color = Colors.white.withOpacity(0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  Color _colorForScore(double score) {
    if (score >= 0.7) return const Color(0xFF00E676); // green
    if (score >= 0.5) return const Color(0xFFFFEA00); // yellow
    return const Color(0xFFFF5252); // red
  }

  @override
  bool shouldRepaint(SkeletonPainter oldDelegate) => true;
}
