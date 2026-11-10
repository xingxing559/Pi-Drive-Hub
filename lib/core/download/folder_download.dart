import 'dart:collection';

import 'package:path/path.dart' as p;

import '../models/cloud_file.dart';
import '../providers/cloud_provider.dart';
import '../state/download_manager.dart';
import 'download_destination.dart';

class DownloadScanResult {
  int files = 0;
  int folders = 0;
  final List<String> errors = [];
  bool canceled = false;
}

/// Iterative, one-directory-at-a-time traversal: network/IO is always asynchronous.
/// Provider.list MUST return all pages; each file uses the normal bounded queue.
class FolderDownload {
  FolderDownload(this.manager);
  final DownloadManager manager;

  Future<DownloadScanResult> enqueue(
    CloudProvider provider,
    List<CloudFile> selected,
    String directory, {
    bool Function()? isCanceled,
    void Function(DownloadScanResult)? onProgress,
  }) async {
    final result = DownloadScanResult();
    final epoch = manager.epoch;
    final destination = await DownloadDestination.open(
      directory,
      reserved: manager.tasks.map((t) => p.join(t.localDir, t.name)),
    );
    bool canceled() => manager.epoch != epoch || (isCanceled?.call() ?? false);
    const maxEntries = 100000;
    final pending = Queue<(CloudFile, String, int)>();
    // Selecting both a parent and its descendant should not download twice.
    final roots = selected.where(
      (item) =>
          !selected.any(
            (other) =>
                other.isDir &&
                other.path != item.path &&
                item.path.startsWith('${other.path}/'),
          ),
    );
    for (final root in roots) {
      pending.add((root, destination.root, 0));
    }
    final visited = <String>{};
    while (pending.isNotEmpty && !canceled()) {
      if (visited.length >= maxEntries) {
        result.errors.add('扫描数量超出 $maxEntries 项安全上限，剩余项目未加入下载');
        break;
      }
      final (item, parent, depth) = pending.removeFirst();
      if (!visited.add(item.path)) continue;
      try {
        if (depth > 128) {
          throw const FormatException('目录过深或文件数量超出安全上限');
        }
        final local = await destination.allocate(
          parent,
          item.name,
          directory: item.isDir,
        );
        if (canceled()) break;
        if (!item.isDir) {
          manager.add(
            provider,
            item.path,
            p.dirname(local),
            p.basename(local),
            root: destination.root,
          );
          result.files++;
        } else {
          result.folders++;
          final children = await provider
              .list(item.path)
              .timeout(const Duration(minutes: 2));
          if (canceled()) break;
          for (final child in children) {
            // Never trust server-supplied paths (including aliases and cycles).
            if (child.path != '${item.path}/${child.name}' ||
                child.name == '.' ||
                child.name == '..' ||
                child.name.contains('/') ||
                child.name.contains('\\')) {
              result.errors.add('${child.path}: 非法子路径，已跳过');
              continue;
            }
            if (pending.length + visited.length >= maxEntries) {
              result.errors.add(
                '${item.path}: 超出 $maxEntries 项安全上限，部分子项目未加入下载',
              );
              break;
            }
            pending.add((child, local, depth + 1));
          }
        }
      } catch (e) {
        result.errors.add('${item.path}: $e');
      }
      onProgress?.call(result);
      await Future<void>.delayed(
        Duration.zero,
      ); // let the desktop process input/paint
    }
    result.canceled = canceled();
    return result;
  }
}
