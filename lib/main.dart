import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:windows_single_instance/windows_single_instance.dart';
import 'package:window_manager/window_manager.dart';

import 'app_state.dart';
import 'core/scanner.dart';
import 'ui/app_shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!Platform.isAndroid && !Platform.isIOS) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1360, 860), // 设计书 4.2：默认 1360×860
      minimumSize: Size(960, 600),
      titleBarStyle: TitleBarStyle.hidden, // 无边框窗口，自绘标题栏
      title: 'AgentImageViewer',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  final state = await AppState.create();
  if (!Platform.isAndroid && !Platform.isIOS) {
    // 单实例锁：再次双击图片时把路径转发给已开窗口（设计书 6.1）
    await WindowsSingleInstance.ensureSingleInstance(
      const [],
      'com.dashi929.agent_image_viewer',
      onSecondWindow: (args) {
        final path = extractImagePath(args);
        if (path != null) {
          state.registerExternalOpen(path);
        }
      },
    );
  }
  runApp(AgentImageViewerApp(state: state));
}

class AgentImageViewerApp extends StatelessWidget {
  const AgentImageViewerApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      state: state,
      child: MaterialApp(
        title: 'AgentImageViewer',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        home: Stack(
          children: [
            AppShell(),
            // 自绘标题栏拖动区 + 窗口控制按钮（仅桌面显示）
            const _TitleBar(),
          ],
        ),
      ),
    );
  }
}

/// 从进程参数中提取图片路径（跳过 exe 自身与选项）。
String? extractImagePath(List<String> args) {
  for (final a in args) {
    if (a.endsWith('.exe') || a.startsWith('-') || a.startsWith('/')) continue;
    if (SupportedFormats.isSupported(a)) return a;
  }
  return null;
}

class _TitleBar extends StatelessWidget {
  const _TitleBar();

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid || Platform.isIOS) return const SizedBox.shrink();
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: DragToMoveArea(
              child: Container(color: Colors.transparent),
            ),
          ),
          _WinButton(icon: Icons.remove, onTap: windowManager.minimize),
          _WinButton(icon: Icons.crop_square, onTap: windowManager.maximize),
          _WinButton(
            icon: Icons.close,
            onTap: windowManager.close,
            hoverColor: AppColors.danger,
          ),
        ],
      ),
    );
  }
}

class _WinButton extends StatelessWidget {
  const _WinButton({
    required this.icon,
    required this.onTap,
    this.hoverColor = Colors.white10,
  });

  final IconData icon;
  final VoidCallback onTap;
  final Color hoverColor;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: hoverColor,
        child: SizedBox(
          width: 44,
          height: 36,
          child: Icon(icon, size: 16, color: AppColors.textSecondary),
        ),
      ),
    );
  }
}
