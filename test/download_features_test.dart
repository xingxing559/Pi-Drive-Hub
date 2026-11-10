import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pi_pan/core/download/download_destination.dart';
import 'package:pi_pan/core/download/folder_download.dart';
import 'package:pi_pan/core/download/paginated_listing.dart';
import 'package:pi_pan/core/settings/download_settings.dart';
import 'package:pi_pan/core/state/download_manager.dart';

import 'fake_drive.dart';

void main() {
  late Directory temp;
  late FakeDrive drive;
  late DownloadManager manager;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('pi-download-test-');
    drive = FakeDrive();
    manager = DownloadManager();
  });
  tearDown(() async {
    await temp.delete(recursive: true);
    manager.dispose();
  });

  test('settings persist across reload and reset to default', () async {
    final path = File(p.join(temp.path, 'settings.json'));
    final fallback = p.join(temp.path, 'default');
    final settings = DownloadSettings(file: path, defaultDirectory: fallback);
    final chosen = p.join(temp.path, 'chosen');
    await settings.setDirectory(chosen);
    final reloaded = DownloadSettings(file: path, defaultDirectory: fallback);
    await reloaded.read();
    expect(reloaded.directory, chosen);
    await reloaded.setDirectory(null);
    expect(reloaded.directory, fallback);
    expect(jsonDecode(await path.readAsString())['downloadDirectory'], isNull);
    expect((await Directory(chosen).list().toList()), isEmpty);
  });

  test('corrupt/relative settings safely fall back', () async {
    final path = File(p.join(temp.path, 'settings.json'));
    for (final body in ['broken json', '{"downloadDirectory":"../outside"}']) {
      await path.writeAsString(body);
      final settings = DownloadSettings(
        file: path,
        defaultDirectory: temp.path,
      );
      await settings.read();
      expect(settings.directory, temp.path);
      expect(settings.loadWarning, isNotNull);
    }
  });

  test('failed settings write retains the previous preference', () async {
    final path = File(p.join(temp.path, 'settings.json'));
    final settings = DownloadSettings(file: path, defaultDirectory: temp.path);
    final chosen = p.join(temp.path, 'chosen');
    await settings.setDirectory(chosen);
    final blocker = File(p.join(temp.path, 'not-a-directory'));
    await blocker.writeAsString('keep');
    await expectLater(
      settings.setDirectory(p.join(blocker.path, 'child')),
      throwsA(isA<FileSystemException>()),
    );
    expect(settings.directory, chosen);
  });

  test(
    'all pages including an exact page-size boundary are requested',
    () async {
      final offsets = <int>[];
      final actual = await collectPages<int>(
        pageSize: 2,
        identity: (n) => '$n',
        fetch: (offset, limit) async {
          offsets.add(offset);
          return offset < 4 ? [offset, offset + 1] : [];
        },
      );
      expect(actual, [0, 1, 2, 3]);
      expect(offsets, [0, 2, 4]);
    },
  );

  test('repeated pages fail explicitly instead of looping forever', () async {
    await expectLater(
      collectPages<int>(
        pageSize: 2,
        identity: (n) => '$n',
        fetch: (_, __) async => [1, 2],
      ),
      throwsStateError,
    );
  });

  test('recursive download keeps nested files and empty directories', () async {
    drive.tree['/资料'] = [file('/资料/a.txt'), dir('/资料/子目录'), dir('/资料/空目录')];
    drive.tree['/资料/子目录'] = [file('/资料/子目录/b.txt')];
    final result = await FolderDownload(
      manager,
    ).enqueue(drive, [dir('/资料')], temp.path);
    await finished(manager);
    expect(result.errors, isEmpty);
    expect(result.files, 2);
    expect(result.folders, 3);
    expect(
      await File(p.join(temp.path, '资料', '子目录', 'b.txt')).readAsString(),
      '/资料/子目录/b.txt',
    );
    expect(await Directory(p.join(temp.path, '资料', '空目录')).exists(), isTrue);
    expect(drive.peak, 1);
  });

  test(
    'existing files, case conflicts and sanitized names never overwrite',
    () async {
      await File(p.join(temp.path, 'report.txt')).writeAsString('existing');
      drive.tree['/docs'] = [
        file('/docs/a:b.txt'),
        file('/docs/a?b.txt'),
        file('/docs/CON'),
      ];
      await FolderDownload(
        manager,
      ).enqueue(drive, [file('/REPORT.txt'), dir('/docs')], temp.path);
      await finished(manager);
      expect(
        await File(p.join(temp.path, 'report.txt')).readAsString(),
        'existing',
      );
      expect(await File(p.join(temp.path, 'REPORT (1).txt')).exists(), isTrue);
      expect(await File(p.join(temp.path, 'docs', 'a_b.txt')).exists(), isTrue);
      expect(
        await File(p.join(temp.path, 'docs', 'a_b (1).txt')).exists(),
        isTrue,
      );
      expect(await File(p.join(temp.path, 'docs', '_CON')).exists(), isTrue);
    },
  );

  test('separate enqueues reserve queued destinations too', () async {
    drive.gate = Completer<void>();
    await FolderDownload(manager).enqueue(drive, [file('/x.txt')], temp.path);
    await FolderDownload(manager).enqueue(drive, [file('/x.txt')], temp.path);
    expect(manager.tasks.map((t) => t.name), ['x.txt', 'x (1).txt']);
    drive.gate!.complete();
    await finished(manager);
  });

  test('existing folders are not merged or overwritten', () async {
    await Directory(p.join(temp.path, 'docs')).create();
    final result = await FolderDownload(
      manager,
    ).enqueue(drive, [dir('/docs')], temp.path);
    expect(result.folders, 1);
    expect(await Directory(p.join(temp.path, 'docs (1)')).exists(), isTrue);
  });

  test(
    'parent/child selection deduplicates and unsafe children are skipped',
    () async {
      drive.tree['/root'] = [
        file('/root/ok.txt'),
        file('/root/../escape.txt'),
        dir('/root/cycle'),
      ];
      drive.tree['/root/cycle'] = [dir('/root')];
      final result = await FolderDownload(
        manager,
      ).enqueue(drive, [dir('/root'), file('/root/ok.txt')], temp.path);
      await finished(manager);
      expect(result.files, 1);
      expect(result.errors, hasLength(2));
      expect(drive.downloaded, ['/root/ok.txt']);
      expect(
        await File(p.join(temp.parent.path, 'escape.txt')).exists(),
        isFalse,
      );
    },
  );

  test(
    'list failure reports partial result and continues other folders',
    () async {
      drive.tree['/root'] = [dir('/root/broken'), file('/root/good.txt')];
      drive.listFailures.add('/root/broken');
      final result = await FolderDownload(
        manager,
      ).enqueue(drive, [dir('/root')], temp.path);
      await finished(manager);
      expect(result.errors.single, contains('模拟列表失败'));
      expect(drive.downloaded, ['/root/good.txt']);
    },
  );

  test(
    'canceled scans stop adding files but preserve already queued tasks',
    () async {
      drive.tree['/root'] = List.generate(20, (i) => file('/root/$i.txt'));
      var cancel = false;
      final result = await FolderDownload(manager).enqueue(
        drive,
        [dir('/root')],
        temp.path,
        isCanceled: () => cancel,
        onProgress: (r) {
          if (r.files == 2) cancel = true;
        },
      );
      await finished(manager);
      expect(result.canceled, isTrue);
      expect(result.files, 2);
    },
  );

  test('account epoch change cancels a scan', () async {
    drive.tree['/root'] = [file('/root/a'), file('/root/b')];
    final result = await FolderDownload(manager).enqueue(
      drive,
      [dir('/root')],
      temp.path,
      onProgress: (r) {
        if (r.folders == 1) manager.cancelAll();
      },
    );
    expect(result.canceled, isTrue);
    expect(result.files, 0);
    expect(manager.tasks, isEmpty);
  });

  test('subdirectory symlinks and traversal names are rejected', () async {
    final outside = await Directory.systemTemp.createTemp('pi-outside-');
    try {
      final link = Link(p.join(temp.path, 'link'));
      await link.create(outside.path);
      await expectLater(
        DownloadDestination.validateDirectory(temp.path, link.path),
        throwsA(isA<FileSystemException>()),
      );
      for (final name in ['..', '.', '../escape', r'a\b', '']) {
        expect(() => safeLocalName(name), throwsFormatException);
      }
    } finally {
      await outside.delete();
    }
  });

  test('download failure is visible and can be retried', () async {
    drive.downloadFailures.add('/bad.txt');
    await FolderDownload(manager).enqueue(drive, [file('/bad.txt')], temp.path);
    await finished(manager);
    final task = manager.tasks.single;
    expect(task.status, DownloadStatus.failed);
    expect(task.error, contains('模拟下载失败'));
    drive.downloadFailures.clear();
    manager.retry(task.id);
    await finished(manager);
    expect(task.status, DownloadStatus.done);
  });

  test(
    'pause does not automatically resume when a later task finishes',
    () async {
      drive.gate = Completer<void>();
      manager.add(drive, '/a', temp.path, 'a');
      manager.add(drive, '/b', temp.path, 'b');
      final first = manager.tasks.first;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      manager.pause(first.id);
      drive.gate!.complete();
      await waitFor(
        manager,
        () => manager.tasks.last.status == DownloadStatus.done,
      );
      expect(first.status, DownloadStatus.paused);
      manager.resume(first.id);
      await finished(manager);
      expect(first.status, DownloadStatus.done);
      expect(drive.peak, 1);
    },
  );

  test(
    'remove running task releases exactly one slot after writer exits',
    () async {
      drive.gate = Completer<void>();
      for (final name in ['a', 'b', 'c']) {
        manager.add(drive, '/$name', temp.path, name);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      manager.remove(manager.tasks.first.id);
      drive.gate!.complete();
      await finished(manager);
      expect(drive.peak, 1);
      expect(drive.downloaded, ['/b', '/c']);
    },
  );

  test(
    'cancel all while running does not double-release queue capacity',
    () async {
      drive.gate = Completer<void>();
      manager.add(drive, '/old', temp.path, 'old');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      manager.cancelAll();
      manager.add(drive, '/new', temp.path, 'new');
      drive.gate!.complete();
      await finished(manager);
      expect(drive.peak, 1);
      expect(drive.downloaded, ['/new']);
    },
  );

  test(
    'configured directory is captured for both file and folder tasks',
    () async {
      final settings = DownloadSettings(
        file: File(p.join(temp.path, 'settings.json')),
        defaultDirectory: temp.path,
      );
      final chosen = p.join(temp.path, 'selected');
      await settings.setDirectory(chosen);
      drive.tree['/folder'] = [file('/folder/f.txt')];
      await FolderDownload(
        manager,
      ).enqueue(drive, [file('/one.txt'), dir('/folder')], settings.directory);
      await settings.setDirectory(p.join(temp.path, 'next'));
      await finished(manager);
      expect(await File(p.join(chosen, 'one.txt')).exists(), isTrue);
      expect(await File(p.join(chosen, 'folder', 'f.txt')).exists(), isTrue);
      expect(
        manager.tasks.every(
          (t) => p.isWithin(chosen, t.localDir) || p.equals(chosen, t.localDir),
        ),
        isTrue,
      );
    },
  );
  test(
    'bounded concurrency allows two files and never exceeds the cap',
    () async {
      manager.setMaxConcurrent(2);
      drive.gate = Completer<void>();
      for (final name in ['a', 'b', 'c', 'd']) {
        manager.add(drive, '/$name', temp.path, name);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(drive.active, 2);
      drive.gate!.complete();
      await finished(manager);
      expect(drive.peak, 2);
    },
  );

  test(
    'file created after enqueue is not overwritten by a queued task',
    () async {
      drive.gate = Completer<void>();
      manager.add(drive, '/blocking', temp.path, 'blocking');
      manager.add(drive, '/target', temp.path, 'target');
      await File(p.join(temp.path, 'target')).writeAsString('external file');
      drive.gate!.complete();
      await finished(manager);
      expect(manager.tasks.last.status, DownloadStatus.failed);
      expect(
        await File(p.join(temp.path, 'target')).readAsString(),
        'external file',
      );
    },
  );

  test(
    'pause/resume before the writer exits does not start two writers',
    () async {
      manager.setMaxConcurrent(2);
      drive.gate = Completer<void>();
      manager.add(drive, '/a', temp.path, 'a');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final task = manager.tasks.single;
      manager.pause(task.id);
      manager.resume(task.id);
      expect(drive.active, 1);
      drive.gate!.complete();
      await finished(manager);
      expect(task.status, DownloadStatus.done);
      expect(drive.downloaded, ['/a']);
      expect(drive.peak, 1);
    },
  );
}
