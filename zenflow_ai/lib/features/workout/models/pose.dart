enum KeypointType {
  nose(0),
  leftEye(1),
  rightEye(2),
  leftEar(3),
  rightEar(4),
  leftShoulder(5),
  rightShoulder(6),
  leftElbow(7),
  rightElbow(8),
  leftWrist(9),
  rightWrist(10),
  leftHip(11),
  rightHip(12),
  leftKnee(13),
  rightKnee(14),
  leftAnkle(15),
  rightAnkle(16);

  final int index;
  const KeypointType(this.index);
}

class Keypoint {
  final double x;
  final double y;
  final double score;

  const Keypoint({
    required this.x,
    required this.y,
    required this.score,
  });
}

class Pose {
  final Map<KeypointType, Keypoint> keypoints;
  const Pose(this.keypoints);
}
