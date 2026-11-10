import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pi_pan/core/models/cloud_account.dart';
import 'package:pi_pan/core/models/cloud_file.dart';
import 'package:pi_pan/core/providers/auth_provider.dart';
import 'package:pi_pan/core/providers/cloud_provider.dart';
import 'package:pi_pan/core/state/download_manager.dart';

class FakeDrive implements CloudProvider {
  final Map<String, List<CloudFile>> tree = {};
  final Set<String> listFailures = {};
  final Set<String> downloadFailures = {};
  final List<String> downloaded = [];
  Completer<void>? gate;
  int active = 0;
  int peak = 0;
  @override
  String get id => 'fake';
  @override
  String get displayName => '百度网盘';
  @override
  AuthProvider? get auth => null;
  @override
  Future<CloudAccount> getAccountInfo() async =>
      const CloudAccount(providerId: 'fake', displayName: '本地演示账号');
  @override
  Future<List<CloudFile>> list(String path) async {
    if (listFailures.contains(path)) throw StateError('模拟列表失败');
    return tree[path] ?? [];
  }

  @override
  Future<void> download(
    String remotePath,
    String localDir, {
    String? localName,
    TransferProgress? onProgress,
    bool Function()? isCanceled,
    Set<int>? completedBlocks,
    void Function(int, Set<int>)? onBlocks,
  }) async {
    active++;
    if (active > peak) peak = active;
    try {
      if (gate != null) await gate!.future;
      if (isCanceled?.call() ?? false) throw StateError('canceled');
      if (downloadFailures.contains(remotePath)) throw StateError('模拟下载失败');
      final name = localName ?? remotePath.split('/').last;
      await File(p.join(localDir, name)).writeAsString(remotePath);
      downloaded.add(remotePath);
      onProgress?.call(remotePath.length, remotePath.length);
    } finally {
      active--;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CloudFile dir(String path) =>
    CloudFile(path: path, name: path.split('/').last, isDir: true);
CloudFile file(String path) =>
    CloudFile(path: path, name: path.split('/').last, isDir: false, size: 2048);

Future<void> waitFor(DownloadManager manager, bool Function() condition) async {
  if (condition()) return;
  final done = Completer<void>();
  void listener() {
    if (condition() && !done.isCompleted) done.complete();
  }

  manager.addListener(listener);
  try {
    await done.future.timeout(const Duration(seconds: 5));
  } finally {
    manager.removeListener(listener);
  }
}

Future<void> finished(DownloadManager manager) => waitFor(
  manager,
  () => manager.tasks.every(
    (t) =>
        t.status == DownloadStatus.done ||
        t.status == DownloadStatus.failed ||
        t.status == DownloadStatus.paused,
  ),
);
