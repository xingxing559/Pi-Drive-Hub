import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Non-sensitive preferences only; deliberately separate from the token store.
class DownloadSettings extends ChangeNotifier {
  DownloadSettings({required this.file, required this.defaultDirectory});

  final File file;
  final String defaultDirectory;
  String? _customDirectory;
  String? loadWarning;
  String get directory => _customDirectory ?? defaultDirectory;
  bool get isDefault => _customDirectory == null;

  static Future<DownloadSettings> load() async {
    final support = await getApplicationSupportDirectory();
    final downloads = await getDownloadsDirectory();
    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    final settings = DownloadSettings(
      file: File(p.join(support.path, 'download_settings.json')),
      defaultDirectory: p.join(
        downloads?.path ??
            (home == null ? support.path : p.join(home, 'Downloads')),
        'PI Drive Hub',
      ),
    );
    await settings.read();
    return settings;
  }

  Future<void> read() async {
    try {
      if (!await file.exists()) return;
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final value = json['downloadDirectory'];
      if (value != null &&
          (value is! String || value.trim().isEmpty || !p.isAbsolute(value))) {
        throw const FormatException('下载目录无效');
      }
      _customDirectory = value as String?;
    } catch (_) {
      _customDirectory = null;
      loadWarning = '无法读取下载设置，已使用默认目录。请重新保存设置。';
    }
  }

  Future<void> setDirectory(String? value) async {
    if (value != null && (value.trim().isEmpty || !p.isAbsolute(value))) {
      throw const FormatException('请选择绝对路径');
    }
    final target = value ?? defaultDirectory;
    // Validate writability without leaving test files behind.
    await Directory(target).create(recursive: true);
    final probe = await Directory(target).createTemp('.pi-write-check-');
    await probe.delete();
    await file.parent.create(recursive: true);
    // Keep the previous preference if persisting fails.
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'version': 1, 'downloadDirectory': value}),
      flush: true,
    );
    await temporary.rename(file.path);
    _customDirectory = value;
    loadWarning = null;
    notifyListeners();
  }
}
