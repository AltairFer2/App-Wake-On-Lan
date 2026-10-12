import 'package:altair_wake/core/formatting/relative_time.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 11, 18, 0);

  test('formatea intervalos recientes y fechas antiguas', () {
    expect(formatRelativeTime(now, now), 'hace un momento');
    expect(formatRelativeTime(now.add(const Duration(minutes: 1)), now), 'hace un momento');
    expect(formatRelativeTime(now.subtract(const Duration(minutes: 5)), now), 'hace 5 min');
    expect(formatRelativeTime(now.subtract(const Duration(hours: 3)), now), 'hace 3 h');
    expect(formatRelativeTime(DateTime(2026, 10, 1, 9, 5), now), '01/10/2026 09:05');
  });
}
