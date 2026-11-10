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
    final destination = DownloadDestination._(await canonicalDirectory(path));
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

  /// Canonicalize a user-selected root ONCE before creating tasks. Windows may
  /// expand a short 8.3 path; that is not evidence of a symlink below the root.
  static Future<String> canonicalDirectory(
    String directory, {
    p.Context? context,
    Future<String> Function(String)? resolve,
  }) async {
    final normalized = normalizePath(directory, context: context);
    final resolved = await (resolve ?? _resolveDirectory)(normalized);
    return normalizePath(resolved, context: context);
  }

  static Future<String> _resolveDirectory(String directory) =>
      Directory(directory).resolveSymbolicLinks();

  /// Strip only equivalent Windows long-path namespace spellings, never use a
  /// string prefix check for containment (C:\safe2 is not inside C:\safe).
  static String normalizePath(String path, {p.Context? context}) {
    final paths = context ?? p.context;
    if (paths.style == p.Style.windows) {
      if (path.toUpperCase().startsWith(r'\\?\UNC\')) {
        path = r'\\' + path.substring(8);
      } else if (path.startsWith(r'\\?\') &&
          RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path.substring(4))) {
        path = path.substring(4);
      }
    }
    if (!paths.isAbsolute(path) || paths.isRootRelative(path)) {
      throw FileSystemException('下载目录必须是绝对路径', path);
    }
    return paths.normalize(path);
  }

  /// [root] is an immutable canonical snapshot captured at enqueue time, not an
  /// arbitrary alias. Re-resolving and silently REBINDING root would allow an
  /// attacker to replace the root with a junction before a queued task starts.
  static Future<void> validateDirectory(
    String root,
    String directory, {
    p.Context? context,
    Future<String> Function(String)? resolve,
  }) async {
    final paths = context ?? p.context;
    final canonicalRoot = normalizePath(root, context: paths);
    final expected = normalizePath(directory, context: paths);
    if (!paths.equals(canonicalRoot, expected) &&
        !paths.isWithin(canonicalRoot, expected)) {
      throw FileSystemException('下载路径超出目标目录 (root=$canonicalRoot)', directory);
    }
    final resolvedRoot = await canonicalDirectory(
      canonicalRoot,
      context: paths,
      resolve: resolve,
    );
    if (!paths.equals(resolvedRoot, canonicalRoot)) {
      throw FileSystemException(
        '下载根目录已被替换 (expected=$canonicalRoot; resolved=$resolvedRoot)',
        root,
      );
    }
    final relative = paths.relative(expected, from: canonicalRoot);
    final resolved = await canonicalDirectory(
      expected,
      context: paths,
      resolve: resolve,
    );
    if (!paths.equals(resolved, paths.join(canonicalRoot, relative))) {
      throw FileSystemException(
        '下载子目录不能是符号链接或联接 (expected=$expected; resolved=$resolved)',
        directory,
      );
    }
  }
}
