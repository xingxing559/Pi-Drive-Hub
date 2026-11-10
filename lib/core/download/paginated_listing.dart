/// Collect complete listings without silently accepting an ignored page cursor.
Future<List<T>> collectPages<T>({
  required Future<List<T>> Function(int offset, int limit) fetch,
  required String Function(T) identity,
  int pageSize = 1000,
}) async {
  final all = <T>[];
  final seen = <String>{};
  for (var page = 0; page < 10000; page++) {
    final items = await fetch(page * pageSize, pageSize);
    var added = 0;
    for (final item in items) {
      if (seen.add(identity(item))) {
        all.add(item);
        added++;
      }
    }
    if (items.isNotEmpty && added == 0) {
      throw StateError('网盘重复返回同一页，无法完整读取目录');
    }
    if (items.length < pageSize) return all;
  }
  throw StateError('目录分页超出安全上限');
}
