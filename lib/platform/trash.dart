/// 回收站（设计书 5.1/5.3：Del → 移入回收站）。
///
/// Windows 经 PowerShell VisualBasic.FileIO 送回收站（无需管理员）；
/// 命令构建为纯函数（可单测）。
library;

import 'dart:io';

/// 构建送回收站的 PowerShell 参数。纯函数。
List<String> buildRecycleCommand(String path) {
  final p = path.replaceAll("'", "''");
  return [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    "Add-Type -AssemblyName Microsoft.VisualBasic; "
        "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile("
        "'$p', 'OnlyErrorDialogs', 'SendToRecycleBin')",
  ];
}

/// 移入回收站。仅 Windows 桌面返回真实结果，其他平台返回 false。
Future<bool> moveToRecycleBin(String path) async {
  if (!Platform.isWindows || !File(path).existsSync()) return false;
  final r = await Process.run('powershell.exe', buildRecycleCommand(path),
      runInShell: false);
  return r.exitCode == 0;
}
