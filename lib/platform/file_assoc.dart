/// Windows 文件关联与「打开方式」注册（设计书 6.1/6.2）。
///
/// 全部写入 HKCU，无需管理员权限：
/// 1. ProgID（显示名 + 打开命令 + 图标）；
/// 2. 每个扩展名的 OpenWithProgids（右键「打开方式」列表）；
/// 3. Applications\<exe>（「打开方式 → 其他应用」应用列表）；
/// 4. MuiCache 友好名与厂商（资源管理器显示 "AgentImageViewer" 而非 exe 名）。
/// 取消注册清理全部注册项，不残留失效条目（6.2）。
/// 命令构建为纯函数（可单测）；执行仅在 Windows 桌面运行。
library;

import 'dart:io';

/// 默认注册格式（设计书 6.2：svg/heic 因解码差异默认不勾选）。
const defaultAssocExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.avif'];

/// 可选格式（设置页允许手动加入）。
const optionalAssocExtensions = ['.svg', '.ico'];

/// 注册表根（当前用户）。
const _root = r'HKCU\Software\Classes';
const _muiCacheKey =
    r'HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache';

String progIdFor(String exeName) => '$exeName.ImageViewer';

/// MuiCache 友好名条目名：`<exe 完整路径>.FriendlyAppName`。
String muiCacheAppNameValue(String exePath) => '$exePath.FriendlyAppName';

/// MuiCache 厂商条目名：`<exe 完整路径>.ApplicationCompany`。
String muiCacheCompanyValue(String exePath) => '$exePath.ApplicationCompany';

/// 构建注册命令清单。纯函数。
List<List<String>> buildRegisterCommands({
  required String exeName,
  required String exePath,
  required String iconPath,
  required List<String> extensions,
  String displayName = 'AgentImageViewer',
  String company = 'Dashi929',
}) {
  final progId = progIdFor(exeName);
  final cmds = <List<String>>[];

  void addArgs(List<String> a) => cmds.add(a);

  // 1) ProgID：显示名 + 打开命令 + 图标
  addArgs(['add', '$_root\\$progId', '/ve', '/d', '$displayName 图像文件', '/f']);
  addArgs([
    'add', '$_root\\$progId\\shell\\open\\command', '/ve',
    '/d', '"$exePath" "%1"', '/f',
  ]);
  addArgs(['add', '$_root\\$progId\\DefaultIcon', '/ve', '/d', '"$iconPath"', '/f']);

  // 2) 扩展名 → OpenWithProgids（右键「打开方式」列表）
  for (final ext in extensions) {
    final e = ext.startsWith('.') ? ext : '.$ext';
    addArgs([
      'add', '$_root' '\\' '$e\\OpenWithProgids', '/v', progId,
      '/t', 'REG_SZ', '/d', 'AgentImageViewer', '/f',
    ]);
  }

  // 3) Applications\<exe>：「打开方式 → 其他应用」列表
  final appsKey = '$_root\\Applications\\$exeName.exe';
  addArgs(['add', '$appsKey\\shell\\open\\command', '/ve', '/d', '"$exePath" "%1"', '/f']);
  addArgs(['add', '$appsKey\\DefaultIcon', '/ve', '/d', '"$iconPath"', '/f']);
  addArgs(['add', appsKey, '/v', 'FriendlyAppName', '/d', displayName, '/f']);

  // 4) MuiCache：友好名 + 厂商（资源管理器显示用）
  addArgs([
    'add', _muiCacheKey, '/v', muiCacheAppNameValue(exePath),
    '/t', 'REG_SZ', '/d', displayName, '/f',
  ]);
  addArgs([
    'add', _muiCacheKey, '/v', muiCacheCompanyValue(exePath),
    '/t', 'REG_SZ', '/d', company, '/f',
  ]);

  return cmds;
}

/// 构建取消注册命令：ProgID、Applications、各扩展名 OpenWithProgids、
/// MuiCache 条目全部清理，不残留（设计书 6.2）。纯函数。
List<List<String>> buildUnregisterCommands({
  required String exeName,
  required String exePath,
  required List<String> extensions,
}) {
  final progId = progIdFor(exeName);
  final cmds = <List<String>>[
    ['delete', '$_root\\$progId', '/f'],
    ['delete', '$_root\\Applications\\$exeName.exe', '/f'],
    ['delete', _muiCacheKey, '/v', muiCacheAppNameValue(exePath), '/f'],
    ['delete', _muiCacheKey, '/v', muiCacheCompanyValue(exePath), '/f'],
  ];
  for (final ext in extensions) {
    final e = ext.startsWith('.') ? ext : '.$ext';
    cmds.add(['delete', '$_root' '\\' '$e\\OpenWithProgids', '/v', progId, '/f']);
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
      buildUnregisterCommands(exeName: exeName, exePath: exePath, extensions: extensions));
}
