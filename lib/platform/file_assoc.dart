/// Windows 文件关联（设计书 6.1/6.2）：HKCU 注册，无需管理员权限。
///
/// 命令构建为纯函数（可单测）；执行仅在 Windows 桌面运行。
/// 注册结构：HKCU 下 `Software\Classes\<ProgID>` 与 `<ext>\OpenWithProgids`。
library;

import 'dart:io';

/// 默认注册格式（设计书 6.2：svg/heic 因解码差异默认不勾选）。
const defaultAssocExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.avif'];

/// 可选格式（设置页允许手动加入）。
const optionalAssocExtensions = ['.svg', '.ico'];

String progIdFor(String exeName) => '$exeName.ImageViewer';

/// 构建注册命令清单：`(reg add 参数数组)` 列表。纯函数。
List<List<String>> buildRegisterCommands({
  required String exeName,
  required String exePath,
  required String iconPath,
  required List<String> extensions,
}) {
  final progId = progIdFor(exeName);
  final root = r'HKCU\Software\Classes';
  final cmds = <List<String>>[];

  // 1) ProgID：显示名 + 打开命令 + 图标
  void addArgs(List<String> a) => cmds.add(a);
  addArgs([
    'add', '$root\\$progId', '/ve', '/d', 'AgentImageViewer 图像文件', '/f',
  ]);
  addArgs([
    'add', '$root\\$progId\\shell\\open\\command', '/ve',
    '/d', '"$exePath" "%1"', '/f',
  ]);
  addArgs([
    'add', '$root\\$progId\\DefaultIcon', '/ve', '/d', '"$iconPath"', '/f',
  ]);

  // 2) 每个扩展名 → OpenWithProgids
  for (final ext in extensions) {
    final e = ext.startsWith('.') ? ext : '.$ext';
    addArgs([
      'add', '$root$e\\OpenWithProgids', '/v', progId, '/t', 'REG_SZ',
      '/d', 'AgentImageViewer', '/f',
    ]);
  }
  return cmds;
}

/// 构建取消注册命令：清理全部注册项，不残留（设计书 6.2）。纯函数。
List<List<String>> buildUnregisterCommands({
  required String exeName,
  required List<String> extensions,
}) {
  final progId = progIdFor(exeName);
  final root = r'HKCU\Software\Classes';
  final cmds = <List<String>>[
    ['delete', '$root\\$progId', '/f', '/va'],
    ['delete', '$root\\$progId\\shell\\open\\command', '/f', '/va'],
    ['delete', '$root\\$progId\\DefaultIcon', '/f', '/va'],
  ];
  for (final ext in extensions) {
    final e = ext.startsWith('.') ? ext : '.$ext';
    cmds.add(['delete', '$root$e\\OpenWithProgids', '/v', progId, '/f']);
  }
  return cmds;
}

/// 执行 reg 命令清单。仅 Windows；返回是否全部成功。
Future<bool> execRegCommands(List<List<String>> commands) async {
  if (!Platform.isWindows) return false;
  for (final args in commands) {
    final r = await Process.run('reg', args, runInShell: true);
    if (r.exitCode != 0) return false;
  }
  return true;
}

class FileAssoc {
  FileAssoc({required this.exeName, required this.exePath, required this.iconPath});

  final String exeName;
  final String exePath;
  final String iconPath;

  Future<bool> register(List<String> extensions) => execRegCommands(
      buildRegisterCommands(exeName: exeName, exePath: exePath, iconPath: iconPath, extensions: extensions));

  Future<bool> unregister(List<String> extensions) => execRegCommands(
      buildUnregisterCommands(exeName: exeName, extensions: extensions));
}
