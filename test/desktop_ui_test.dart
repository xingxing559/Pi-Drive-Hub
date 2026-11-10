import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pi_pan/core/models/cloud_account.dart';
import 'package:pi_pan/core/providers/cloud_provider.dart';
import 'package:pi_pan/core/settings/download_settings.dart';
import 'package:pi_pan/core/state/app_state.dart';
import 'package:pi_pan/core/state/download_manager.dart';
import 'package:pi_pan/ui/file_browser_page.dart';
import 'package:pi_pan/ui/settings_page.dart';

import 'fake_drive.dart';

class DemoState extends AppState {
  DemoState(this.drive, DownloadSettings settings)
    : super(downloadSettings: settings);
  final FakeDrive drive;
  @override
  CloudProvider? get currentProvider => drive;
  @override
  CloudAccount? get account => const CloudAccount(
    providerId: 'fake',
    displayName: '本地测试账号',
    usedQuota: 128 * 1024 * 1024 * 1024,
    totalQuota: 2 * 1024 * 1024 * 1024 * 1024,
    vipType: 0,
  );
}

void main() {
  final font = Platform.environment['PI_UI_FONT'];
  setUpAll(() async {
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    if (font != null) {
      final loader = FontLoader('UiTestFont')..addFont(
        File(font).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
      );
      await loader.load();
    }
  });

  Future<void> capture(WidgetTester tester, String name) async {
    final path = Platform.environment['PI_UI_CAPTURE_DIR'];
    if (path == null) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('capture')),
      );
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(path).create(recursive: true);
      await File(p.join(path, name)).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Widget shell(Widget child, {bool dark = false}) => RepaintBoundary(
    key: const Key('capture'),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: font == null ? null : 'UiTestFont',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3978F6),
          brightness: dark ? Brightness.dark : Brightness.light,
        ),
        scaffoldBackgroundColor: dark ? null : const Color(0xFFF4F6FA),
      ),
      home: child,
    ),
  );

  testWidgets(
    'desktop file browser exposes folder download and settings, no overflow',
    (tester) async {
      tester.view.resetPhysicalSize();
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final drive =
          FakeDrive()
            ..tree['/'] = [
              dir('/工作文档'),
              dir('/旅行照片'),
              dir('/视频收藏'),
              file('/项目计划.pdf'),
              file('/产品说明.docx'),
              file('/会议记录.txt'),
            ];
      final settings = DownloadSettings(
        file: File('/unused-demo-settings.json'),
        defaultDirectory: '/demo/downloads/PI Drive Hub',
      );
      final state = DemoState(drive, settings);
      await tester.pumpWidget(shell(FileBrowserPage(appState: state)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('工作空间'), findsOneWidget);
      expect(find.byTooltip('下载整个文件夹'), findsNWidgets(3));
      await capture(tester, 'desktop-files.png');
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('默认下载目录'), findsOneWidget);
      expect(find.text('/demo/downloads/PI Drive Hub'), findsOneWidget);
      await capture(tester, 'desktop-settings.png');
      await tester.pumpWidget(const SizedBox());
      state.downloadManager.dispose();
      state.uploadManager.dispose();
      state.dispose();
    },
  );

  testWidgets('compact layout and dark theme have no overflow', (tester) async {
    tester.view.physicalSize = const Size(720, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final drive = FakeDrive()..tree['/'] = [dir('/文档'), file('/a.txt')];
    final state = DemoState(
      drive,
      DownloadSettings(file: File('/unused.json'), defaultDirectory: '/demo'),
    );
    await tester.pumpWidget(
      shell(FileBrowserPage(appState: state), dark: true),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('工作空间'), findsNothing);
    expect(find.byTooltip('设置'), findsOneWidget);
    await capture(tester, 'compact-dark.png');
    await tester.pumpWidget(const SizedBox());
    state.downloadManager.dispose();
    state.uploadManager.dispose();
    state.dispose();
  });

  testWidgets('settings picker cancellation changes nothing', (tester) async {
    final settings = DownloadSettings(
      file: File('/unused.json'),
      defaultDirectory: '/demo',
    );
    await tester.pumpWidget(
      shell(SettingsPage(settings: settings, pickDirectory: () async => null)),
    );
    await tester.tap(find.text('更改目录'));
    await tester.pumpAndSettle();
    expect(settings.directory, '/demo');
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings picker saves and reset updates the visible path', (
    tester,
  ) async {
    final temp =
        (await tester.runAsync(
          () => Directory.systemTemp.createTemp('pi-settings-ui-'),
        ))!;
    final settings = DownloadSettings(
      file: File(p.join(temp.path, 'settings.json')),
      defaultDirectory: p.join(temp.path, 'default'),
    );
    final chosen = p.join(temp.path, 'chosen');
    await tester.pumpWidget(
      shell(
        SettingsPage(settings: settings, pickDirectory: () async => chosen),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('更改目录'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text(chosen), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('恢复默认'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text(settings.defaultDirectory), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => temp.delete(recursive: true));
  });
  testWidgets(
    'folder button downloads its children into the configured directory',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final temp =
          (await tester.runAsync(
            () => Directory.systemTemp.createTemp('pi-folder-ui-'),
          ))!;
      final drive =
          FakeDrive()
            ..tree['/'] = [dir('/文档')]
            ..tree['/文档'] = [file('/文档/测试.txt')];
      final state = DemoState(
        drive,
        DownloadSettings(
          file: File(p.join(temp.path, 'settings.json')),
          defaultDirectory: temp.path,
        ),
      );
      await tester.pumpWidget(shell(FileBrowserPage(appState: state)));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('下载整个文件夹'));
        await waitFor(
          state.downloadManager,
          () => state.downloadManager.tasks.isNotEmpty,
        );
        await finished(state.downloadManager);
        expect(await File(p.join(temp.path, '文档', '测试.txt')).exists(), isTrue);
        expect(state.downloadManager.tasks.single.status, DownloadStatus.done);
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('已加入 1 个文件'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => temp.delete(recursive: true));
      state.downloadManager.dispose();
      state.uploadManager.dispose();
      state.dispose();
    },
  );
}
