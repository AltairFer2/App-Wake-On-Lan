/// Describe [moment] respecto de [now] en español ("hace 5 min").
String formatRelativeTime(DateTime moment, DateTime now) {
  final elapsed = now.difference(moment);
  if (elapsed.isNegative || elapsed.inMinutes < 1) return 'hace un momento';
  if (elapsed.inHours < 1) return 'hace ${elapsed.inMinutes} min';
  if (elapsed.inDays < 1) return 'hace ${elapsed.inHours} h';
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(moment.day)}/${two(moment.month)}/${moment.year} '
      '${two(moment.hour)}:${two(moment.minute)}';
}
