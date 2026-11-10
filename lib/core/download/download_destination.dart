import 'dart:io';

import 'package:path/path.dart' as p;

/// A remote name is always one component, never a local path.
String safeLocalName(String name) {
  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      name.contains('/') ||
      name.contains('\\')) {
    throw FormatException('不安全的文件名: $name');
  }
  var safe = name
      .replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (safe.isEmpty) safe = '_';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)',
    caseSensitive: false,
  ).hasMatch(safe)) {
    safe = '_$safe';
  }
  // Leave room for conflict suffixes and Windows' per-component limit.
  if (safe.length > 180) safe = safe.substring(0, 180);
  return safe;
}

class DownloadDestination {
  DownloadDestination._(this.root);
  final String root;
  final Set<String> _reserved = {};
  final Map<String, Set<String>> _existingNames = {};

  static Future<DownloadDestination> open(
    String path, {
    Iterable<String> reserved = const [],
  }) async {
    await Directory(path).create(recursive: true);
    final destination = DownloadDestination._(
      await Directory(path).resolveSymbolicLinks(),
    );
    destination._reserved.addAll(reserved.map((e) => e.toLowerCase()));
    return destination;
  }

  Future<String> allocate(
    String parent,
    String name, {
    required bool directory,
  }) async {
    await validateDirectory(root, parent);
    final safe = safeLocalName(name);
    final extension = directory ? '' : p.extension(safe);
    final stem =
        extension.isEmpty
            ? safe
            : safe.substring(0, safe.length - extension.length);
    for (var index = 0; index < 10000; index++) {
      final candidate = p.join(
        parent,
        index == 0 ? safe : '$stem ($index)$extension',
      );
      final key =
          candidate.toLowerCase(); // Windows conflicts are case-insensitive.
      if (_reserved.contains(key)) continue;
      _reserved.add(key); // Reserve before the asynchronous filesystem lookup.
      if (await FileSystemEntity.type(candidate, followLinks: false) !=
              FileSystemEntityType.notFound ||
          (await _namesIn(
            parent,
          )).contains(p.basename(candidate).toLowerCase())) {
        continue;
      }
      if (directory) await Directory(candidate).create();
      return candidate;
    }
    throw FileSystemException('同名文件过多', parent);
  }

  Future<Set<String>> _namesIn(String parent) async {
    final cached = _existingNames[parent];
    if (cached != null) return cached;
    final names = <String>{};
    await for (final entry in Directory(parent).list(followLinks: false)) {
      names.add(p.basename(entry.path).toLowerCase());
    }
    return _existingNames[parent] = names;
  }

  /// Check containment and reject links/junctions introduced below the chosen root.
  static Future<void> validateDirectory(String root, String directory) async {
    if (!p.equals(root, directory) && !p.isWithin(root, directory)) {
      throw FileSystemException('下载路径超出目标目录', directory);
    }
    final resolved = await Directory(directory).resolveSymbolicLinks();
    if (!p.equals(p.normalize(resolved), p.normalize(directory))) {
      throw FileSystemException('下载子目录不能是符号链接或联接', directory);
    }
  }
}
