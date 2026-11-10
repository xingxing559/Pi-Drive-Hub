import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/settings/download_settings.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.settings, this.pickDirectory});
  final DownloadSettings settings;
  final Future<String?> Function()? pickDirectory;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _saving = false;
  String? _error;

  Future<void> _save({bool reset = false}) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final path =
          reset
              ? null
              : await (widget.pickDirectory?.call() ??
                  FilePicker.platform.getDirectoryPath(
                    dialogTitle: '选择默认下载目录',
                  ));
      if (!reset && path == null) return;
      await widget.settings.setDirectory(path);
    } catch (e) {
      if (mounted) setState(() => _error = '保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('设置')),
    body: ListenableBuilder(
      listenable: widget.settings,
      builder:
          (context, _) => ListView(
            padding: const EdgeInsets.all(32),
            children: [
              Text('下载设置', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              const Text('新任务使用此目录；已在队列中的任务不受影响。'),
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.folder_open_outlined),
                          SizedBox(width: 12),
                          Text(
                            '默认下载目录',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SelectableText(
                        widget.settings.directory,
                        key: const Key('download-directory'),
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: _saving ? null : _save,
                            icon: const Icon(
                              Icons.drive_folder_upload_outlined,
                            ),
                            label: const Text('更改目录'),
                          ),
                          OutlinedButton(
                            onPressed:
                                _saving || widget.settings.isDefault
                                    ? null
                                    : () => _save(reset: true),
                            child: const Text('恢复默认'),
                          ),
                        ],
                      ),
                      if (_saving)
                        const Padding(
                          padding: EdgeInsets.only(top: 16),
                          child: LinearProgressIndicator(),
                        ),
                      if (_error != null || widget.settings.loadWarning != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Text(
                            _error ?? widget.settings.loadWarning!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const ListTile(
                leading: Icon(Icons.folder_copy_outlined),
                title: Text('完整保留文件夹结构'),
                subtitle: Text(
                  '包含子文件夹和空目录。同名目标自动加编号，不覆盖原文件；Windows 非法字符替换为下划线。',
                ),
              ),
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('下载说明'),
                subtitle: Text(
                  '文件夹会先逐步扫描并加入传输队列。暂停、继续和单个任务失败信息可在传输中心查看；下载速度仍受网盘账号限制。',
                ),
              ),
            ],
          ),
    ),
  );
}
