import 'dart:math' as math;

class MathUtils {
  /// Calculates the Euclidean distance between two 2D points.
  static double distance(double x1, double y1, double x2, double y2) {
    return math.sqrt(math.pow(x2 - x1, 2) + math.pow(y2 - y1, 2));
  }

  /// Calculates the angle at vertex B formed by points A, B, and C.
  /// Uses the Law of Cosines: theta = arccos((a^2 + c^2 - b^2) / (2ac))
  /// where B is the vertex, a is length BC, c is length AB, and b is length AC.
  /// Returns the angle in degrees.
  static double calculateAngle(
    double ax, double ay,
    double bx, double by, // Vertex
    double cx, double cy,
  ) {
    // Lengths of sides of the triangle
    double a = distance(bx, by, cx, cy); // Distance BC
    double c = distance(ax, ay, bx, by); // Distance AB
    double b = distance(ax, ay, cx, cy); // Distance AC

    // Avoid division by zero if points overlap
    if (a == 0 || c == 0) return 0.0;

    double cosTheta = (math.pow(a, 2) + math.pow(c, 2) - math.pow(b, 2)) / (2 * a * c);
    
    // Clamp to [-1.0, 1.0] to prevent NaN due to floating point inaccuracies
    cosTheta = cosTheta.clamp(-1.0, 1.0);

    double angleRadians = math.acos(cosTheta);
    return angleRadians * (180.0 / math.pi);
  }
}
