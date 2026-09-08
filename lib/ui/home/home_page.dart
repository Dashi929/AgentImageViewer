/// 主页（即时浏览入口）：打开图片 / 打开文件夹，打开后进入浏览视图。
library;

import 'dart:io' show Directory, Platform;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../app_state.dart';
import '../theme.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _busy = false;
  String? _error;

  /// 与 SupportedFormats.all 对齐（无点）。
  static const _exts = [
    'jpg', 'jpeg', 'png', 'bmp', 'gif', 'webp', 'svg', 'avif', 'ico', 'heic', 'heif',
  ];

  Future<void> _openFile() async {
    _clearError();
    var path = '';
    try {
      final picked = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: '图片', extensions: _exts),
        ],
      );
      path = picked?.path ?? '';
    } catch (_) {
      // 平台不支持系统对话框（移动端）：退化为输入路径
      path = await _inputPath('打开图片', r'例如 E:\Pictures\a.jpg') ?? '';
    }
    if (path.isEmpty || !mounted) return;
    final app = AppStateScope.of(context, listen: false);
    _setBusy(true);
    final err = await app.openFile(path);
    if (!mounted) return;
    _setBusy(false);
    if (err != null) _setError(err);
  }

  Future<void> _openFolder() async {
    _clearError();
    var path = '';
    try {
      path = await getDirectoryPath() ?? '';
    } catch (_) {
      path = await _inputPath('打开文件夹', r'例如 E:\Pictures') ?? '';
    }
    if (path.isEmpty || !mounted) return;
    if (Platform.isAndroid || Platform.isIOS) {
      final ok = await _ensureMediaPermission();
      if (!ok) {
        if (mounted) _setError('未获得相册读取权限，请在系统设置中授权后重试');
        return;
      }
    }
    if (!Directory(path).existsSync()) {
      if (mounted) _setError('文件夹不存在：$path');
      return;
    }
    if (!mounted) return;
    final app = AppStateScope.of(context, listen: false);
    _setBusy(true);
    final err = await app.openFolder(path);
    if (!mounted) return;
    _setBusy(false);
    if (err != null) _setError(err);
  }

  Future<bool> _ensureMediaPermission() async {
    try {
      final permission = Permission.photos;
      var st = await permission.request();
      if (!st.isGranted && Platform.isAndroid) {
        st = await Permission.storage.request();
      }
      return st.isGranted;
    } catch (_) {
      return true; // 权限插件异常时不阻塞，交给扫描报错
    }
  }

  Future<String?> _inputPath(String title, String hint) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('打开')),
        ],
      ),
    );
  }

  void _setBusy(bool v) => setState(() {
        _busy = v;
        if (v) _error = null;
      });

  void _clearError() => setState(() => _error = null);
  void _setError(String e) => setState(() => _error = e);

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): _openFile,
      },
      child: Focus(
        autofocus: true,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.image_outlined, size: 56,
                  color: AppColors.textSecondary),
              const SizedBox(height: 14),
              const Text('AgentImageViewer',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  '即开即看：打开一张图片即按所在文件夹连续浏览\n'
                  '← / → 翻页；到头再按一次，跳进上一个 / 下一个图片文件夹',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5,
                      height: 1.6, color: AppColors.textSecondary),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _openFile,
                    icon: const Icon(Icons.photo_outlined, size: 18),
                    label: const Text('打开图片 (Ctrl+O)'),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _openFolder,
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('打开文件夹'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (_busy)
                const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              if (!_busy && _error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(_error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12.5,
                          color: AppColors.danger)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
