import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pi_pan/core/download/download_destination.dart';

void main() {
  final windows = p.Context(style: p.Style.windows, current: r'C:\');
  const alias = r'C:\Users\RUNNER~1\AppData\Local\Temp\pi-test';
  const canonical = r'C:\Users\runneradmin\AppData\Local\Temp\pi-test';

  test(
    'Windows selected-root alias is resolved before containment is checked',
    () async {
      Future<String> resolve(String path) async {
        if (windows.equals(path, alias)) return r'\\?\' + canonical;
        return r'\\?\' + path;
      }

      final root = await DownloadDestination.canonicalDirectory(
        alias,
        context: windows,
        resolve: resolve,
      );
      expect(root, canonical);
      await DownloadDestination.validateDirectory(
        root,
        windows.join(root, '照片'),
        context: windows,
        resolve: resolve,
      );
      // Demonstrates the old bug: an uncaptured 8.3 root is not the same lexical
      // identity as the canonical root, even though it selects that directory.
      await expectLater(
        DownloadDestination.validateDirectory(
          alias,
          alias,
          context: windows,
          resolve: resolve,
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'Windows drive case, slash and extended-path spelling are equivalent',
    () async {
      await DownloadDestination.validateDirectory(
        r'C:\Downloads',
        r'c:/Downloads/文档',
        context: windows,
        resolve: (path) async => r'\\?\' + path,
      );
      expect(
        DownloadDestination.normalizePath(
          r'\\?\C:\Downloads\文档',
          context: windows,
        ),
        r'C:\Downloads\文档',
      );
    },
  );

  test('Windows extended UNC roots normalize to the same share', () async {
    expect(
      DownloadDestination.normalizePath(
        r'\\?\UNC\server\share\downloads',
        context: windows,
      ),
      r'\\server\share\downloads',
    );
    await DownloadDestination.validateDirectory(
      r'\\server\share\downloads',
      r'\\server\share\downloads\照片',
      context: windows,
      resolve: (path) async => path,
    );
  });

  test(
    'Windows sibling-prefix and dotdot traversal never pass containment',
    () async {
      for (final path in [
        r'C:\Downloads-other\file',
        r'C:\Downloads\..\outside',
        r'D:\Downloads',
      ]) {
        await expectLater(
          DownloadDestination.validateDirectory(
            r'C:\Downloads',
            path,
            context: windows,
            resolve: (path) async => path,
          ),
          throwsA(isA<FileSystemException>()),
        );
      }
    },
  );

  test('Windows rooted-relative and drive-relative paths are rejected', () {
    for (final path in [r'\Downloads', r'C:Downloads', 'Downloads']) {
      expect(
        () => DownloadDestination.normalizePath(path, context: windows),
        throwsA(isA<FileSystemException>()),
      );
    }
  });

  test(
    'Windows child junctions are rejected even when target stays inside root',
    () async {
      for (final target in [r'C:\Outside', r'C:\Downloads\other']) {
        await expectLater(
          DownloadDestination.validateDirectory(
            r'C:\Downloads',
            r'C:\Downloads\link',
            context: windows,
            resolve:
                (path) async =>
                    windows.equals(path, r'C:\Downloads\link') ? target : path,
          ),
          throwsA(isA<FileSystemException>()),
        );
      }
    },
  );

  test(
    'Windows captured root cannot be rebound to a replacement junction',
    () async {
      await expectLater(
        DownloadDestination.validateDirectory(
          r'C:\Downloads',
          r'C:\Downloads\sub',
          context: windows,
          resolve:
              (path) async =>
                  path.replaceFirst(r'C:\Downloads', r'D:\Elsewhere'),
        ),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
}
