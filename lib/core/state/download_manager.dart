/// 下载管理器：管理多个下载任务，支持暂停/继续/删除，
/// 并控制同时下载数量（SVIP 可多任务并发，普通账号受限）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../download/download_destination.dart';

import '../constants.dart';
import '../providers/cloud_provider.dart';

enum DownloadStatus { queued, downloading, paused, done, failed, canceled }

class DownloadTask {
  final String id;
  final String remotePath;
  final String name;
  final String localDir;
  final String root;
  bool hasStarted = false;
  DownloadStatus status = DownloadStatus.queued;
  int received = 0;
  int? total;
  String? error;

  DateTime _lastSample = DateTime.now();
  int _lastBytes = 0;
  double _speedBps = 0;

  /// 断点续传：已完成的分片索引（暂停时保存，继续时跳过）
  Set<int> completedBlocks = {};

  /// 任务代数：每次暂停/继续递增，旧下载线程检测到代数不匹配立即退出，
  /// 防止新旧线程并发下载写同一文件

  DownloadTask({
    required this.id,
    required this.remotePath,
    required this.name,
    required this.localDir,
    required this.root,
  });

  double get speedBps => _speedBps;

  String get speedText {
    if (status != DownloadStatus.downloading) return '';
    final s = _speedBps;
    if (s < 1024) return '${s.toStringAsFixed(0)} B/s';
    if (s < 1024 * 1024) return '${(s / 1024).toStringAsFixed(1)} KB/s';
    return '${(s / 1024 / 1024).toStringAsFixed(1)} MB/s';
  }

  bool updateProgress(int done, int? totalBytes) {
    final now = DateTime.now();
    final dt = now.difference(_lastSample).inMilliseconds;
    final delta = done - _lastBytes;
    if (dt >= 200 && delta >= 0) {
      _speedBps = delta / (dt / 1000.0);
      _lastSample = now;
      _lastBytes = done;
    }
    received = done;
    total = totalBytes;
    return dt >= 200;
  }

  double get progress {
    final t = total;
    if (t == null || t == 0) return 0;
    return (received / t).clamp(0.0, 1.0);
  }

  String get statusText {
    switch (status) {
      case DownloadStatus.queued:
        return '等待中';
      case DownloadStatus.downloading:
        return '下载中 ${_fmt(received)}${total != null ? ' / ${_fmt(total!)}' : ''}';
      case DownloadStatus.paused:
        return '已暂停${received > 0 ? '（${_fmt(received)}）' : ''}';
      case DownloadStatus.done:
        return '已完成';
      case DownloadStatus.failed:
        return '失败: $error';
      case DownloadStatus.canceled:
        return '已取消';
    }
  }

  static String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class DownloadManager extends ChangeNotifier {
  final List<DownloadTask> tasks = [];

  /// 当前使用的 Provider（add 时记录，供 resume/pause 调度用）
  final Map<String, CloudProvider> _providers = {};
  final Set<String> _running = {};
  int _nextId = 0;
  int epoch = 0;

  /// 同时下载的任务数量上限（SVIP 可调大，普通账号受限）
  int maxConcurrent = 1;

  /// 设置并发上限并立即重新调度（UI 加减按钮调用）
  void setMaxConcurrent(int n) {
    maxConcurrent = n.clamp(1, kSvipMaxConcurrent);
    notifyListeners();
    _schedule();
  }

  /// 根据账号类型设置并发上限：
  /// - SVIP(vipType>=2)：最多 8 个任务同时下载
  /// - 普通账号：最多 1 个
  void applyVipConcurrency(int vipType) {
    setMaxConcurrent(
      (vipType >= 2) ? kSvipMaxConcurrent : kNormalMaxConcurrent,
    );
  }

  int _activeCount = 0;
  final Set<String> _canceledIds = {};
  final Map<String, int> _generations = {};

  /// 添加下载任务（进入排队，由 [_schedule] 决定何时开始）
  Future<void> add(
    CloudProvider provider,
    String remotePath,
    String localDir,
    String name, {
    String? root,
  }) async {
    final requestEpoch = epoch;
    if (safeLocalName(name) != name) {
      throw const FormatException('本地文件名未经安全处理');
    }
    // Legacy single-file callers may pass an 8.3/alias directory. Resolve it
    // once at enqueue; explicitly supplied roots are already canonical snapshots.
    final canonicalRoot =
        root == null
            ? await DownloadDestination.canonicalDirectory(localDir)
            : DownloadDestination.normalizePath(root);
    final canonicalDir =
        root == null
            ? canonicalRoot
            : DownloadDestination.normalizePath(localDir);
    await DownloadDestination.validateDirectory(canonicalRoot, canonicalDir);
    if (requestEpoch != epoch) {
      throw StateError('账号已切换，未添加下载任务');
    }
    final task = DownloadTask(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_nextId++}',
      remotePath: remotePath,
      name: name,
      localDir: canonicalDir,
      root: canonicalRoot,
    );
    _providers[task.id] = provider;
    _generations[task.id] = 0;
    // 新任务追加到列表末尾（最新任务在下方），
    // 避免批量下载时先添加的文件沉底、下载完成后无法暂停的困惑
    tasks.add(task);
    notifyListeners();
    _schedule();
  }

  /// 调度：在并发上限内启动排队中的任务。
  /// 用户暂停的任务只在明确点击继续后恢复。
  void _schedule() {
    while (_activeCount < maxConcurrent) {
      DownloadTask? next;
      // 优先取排队中的任务
      for (final t in tasks) {
        if (t.status == DownloadStatus.queued && !_running.contains(t.id)) {
          next = t;
          break;
        }
      }
      if (next == null) break;
      _activeCount++;
      _running.add(next.id);
      _run(_providers[next.id]!, next);
    }
  }

  Future<void> _run(CloudProvider provider, DownloadTask task) async {
    task.status = DownloadStatus.downloading;
    // 本线程捕获自己的代数快照（局部变量，不受共享 task 对象影响）
    final myGeneration = _generations[task.id] ?? 0;
    notifyListeners();
    try {
      await DownloadDestination.validateDirectory(task.root, task.localDir);
      final target = p.join(task.localDir, task.name);
      final type = await FileSystemEntity.type(target, followLinks: false);
      if (type == FileSystemEntityType.link ||
          type == FileSystemEntityType.directory ||
          (!task.hasStarted && type != FileSystemEntityType.notFound)) {
        throw FileSystemException('目标文件已存在或不是普通文件，未覆盖', target);
      }
      if (_generations[task.id] != myGeneration ||
          task.status != DownloadStatus.downloading) {
        return;
      }
      task.hasStarted = true;
      await provider.download(
        task.remotePath,
        task.localDir,
        localName: task.name,
        onProgress: (done, total) {
          if (_generations[task.id] != myGeneration ||
              task.status != DownloadStatus.downloading) {
            return;
          }
          // 节流：chunk 级回调很频繁，仅每 200ms 刷新一次 UI
          if (task.updateProgress(done, total)) {
            notifyListeners();
          }
        },
        isCanceled:
            () =>
                _canceledIds.contains(task.id) ||
                _generations[task.id] != myGeneration,
        completedBlocks: task.completedBlocks,
        onBlocks: (done, blocks) {
          // Old writer exits before resume starts, so retain its last committed blocks.
          task.completedBlocks = Set<int>.from(blocks);
        },
      );
      if (_generations[task.id] == myGeneration &&
          task.status != DownloadStatus.paused &&
          task.status != DownloadStatus.canceled) {
        task.status = DownloadStatus.done;
      }
    } catch (e) {
      // 代数已过期：此线程是被暂停/继续淘汰的旧线程，
      // 不标记失败（任务状态已由 resume 改为 queued/新线程接管）
      if (_generations[task.id] != myGeneration) {
        // 旧线程让位，忽略其取消异常
      } else if (task.status == DownloadStatus.paused) {
        // 暂停中断，保持暂停状态
      } else if (task.status != DownloadStatus.canceled) {
        task.status = DownloadStatus.failed;
        task.error = '$e';
      }
    } finally {
      _activeCount--;
      _running.remove(task.id);
      if (task.status == DownloadStatus.canceled) {
        await _cleanupLocalFile(task);
        _providers.remove(task.id);
      }
      notifyListeners();
      _schedule();
    }
  }

  /// 暂停任务：旧线程退出后才释放并发槽位
  void pause(String id) {
    final t = _byId(id);
    if (t == null) return;
    final wasRunning = t.status == DownloadStatus.downloading;
    _generations[id] = (_generations[id] ?? 0) + 1; // 旧线程代数失效，立即中断
    _canceledIds.add(id); // 下载线程检测到后自行退出
    if (wasRunning || t.status == DownloadStatus.queued) {
      t.status = DownloadStatus.paused;
    }

    // 注意：不立即让出槽位/调度——旧下载线程退出后（_run 收尾）才释放，
    // 确保同一任务同时只有一个下载线程在写文件
    notifyListeners();
  }

  /// 继续任务（断点续传：保留已完成分片）
  void resume(String id) {
    final t = _byId(id);
    if (t == null || t.status != DownloadStatus.paused) return;
    _canceledIds.remove(id);
    _generations[id] = (_generations[id] ?? 0) + 1; // 新线程新代数
    t.status = DownloadStatus.queued;
    t.error = null;
    notifyListeners();
    _schedule();
  }

  void retry(String id) {
    final task = _byId(id);
    if (task == null || task.status != DownloadStatus.failed) return;
    task.status = DownloadStatus.queued;
    task.error = null;
    notifyListeners();
    _schedule();
  }

  /// 删除任务（中断并移除，同时清理本地半成品文件）
  void remove(String id) {
    final t = _byId(id);
    if (t == null) return;
    final finished = t.status == DownloadStatus.done;
    _canceledIds.add(id);
    t.status = DownloadStatus.canceled;
    tasks.remove(t);
    if (!_running.contains(id)) {
      if (!finished) _cleanupLocalFile(t);
      _providers.remove(id);
    }
    notifyListeners();
    _schedule();
  }

  Future<void> _cleanupLocalFile(DownloadTask t) async {
    if (t.status == DownloadStatus.done || !t.hasStarted) return;
    try {
      await DownloadDestination.validateDirectory(t.root, t.localDir);
      final path = p.join(t.localDir, t.name);
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.file) {
        await File(path).delete();
      }
    } catch (_) {
      /* Never follow a moved/replaced download directory to clean up. */
    }
  }

  DownloadTask? _byId(String id) {
    for (final t in tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// 任务排序：下载中/排队在前，已完成/失败/暂停沉底
  void sortTasks() {
    int rank(DownloadStatus st) {
      switch (st) {
        case DownloadStatus.downloading:
          return 0;
        case DownloadStatus.queued:
          return 1;
        case DownloadStatus.paused:
          return 2;
        default:
          return 3; // done/failed/canceled
      }
    }

    tasks.sort((a, b) {
      final r = rank(a.status).compareTo(rank(b.status));
      return r != 0 ? r : a.id.compareTo(b.id);
    });
  }

  /// 清除已完成/失败/取消的任务
  void clearFinished() {
    for (final t in tasks) {
      if (t.status == DownloadStatus.done ||
          t.status == DownloadStatus.failed ||
          t.status == DownloadStatus.canceled) {
        _providers.remove(t.id);
        _generations.remove(t.id);
        _canceledIds.remove(t.id);
      }
    }
    tasks.removeWhere(
      (t) =>
          t.status == DownloadStatus.done ||
          t.status == DownloadStatus.failed ||
          t.status == DownloadStatus.canceled,
    );
    notifyListeners();
  }

  /// 取消所有正在进行的任务并清空列表（切换账号时调用）
  void cancelAll() {
    epoch++;
    for (final t in tasks) {
      if (t.status == DownloadStatus.downloading ||
          t.status == DownloadStatus.queued ||
          t.status == DownloadStatus.paused) {
        _canceledIds.add(t.id);
        t.status = DownloadStatus.canceled;
        if (!_running.contains(t.id)) _cleanupLocalFile(t);
      }
      if (!_running.contains(t.id)) _providers.remove(t.id);
    }
    tasks.clear();
    notifyListeners();
  }
}
