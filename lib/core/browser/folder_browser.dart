/// 即时浏览核心：目录内图片列举与相邻图片文件夹导航。
///
/// 去图库后的浏览口径：一次只看一个文件夹（直接子文件，非递归），
/// 文件夹边界由查看器按「同级文件夹」跳转。纯逻辑部分可单测。
library;

import 'dart:io';

import '../scanner.dart';

/// 路径工具与目录扫描。
abstract final class FolderBrowser {
  /// 规范化：去掉结尾分隔符（盘根 `C:\` 与根 `/` 保持原形）。
  static String normalize(String path) {
    var p = path;
    while (p.length > 1 && (p.endsWith('\\') || p.endsWith('/'))) {
      p = p.substring(0, p.length - 1);
    }
    if (p.endsWith(':')) p = '$p\\'; // 剥掉分隔符后剩盘符：C: → C:\
    return p;
  }

  static String nameOf(String path) =>
      normalize(path).split(RegExp(r'[\\/]')).last;

  /// 父目录；根（`C:\`、`/`）返回自身，表示没有同级可跳。
  static String parentOf(String path) {
    final p = normalize(path);
    final i = p.lastIndexOf(RegExp(r'[\\/]'));
    if (i < 0) return p;
    if (i == 0) return p.substring(0, 1); // /root
    if (i == 2 && p[1] == ':') return p.substring(0, 3); // C:\
    return p.substring(0, i);
  }

  static bool _isRoot(String p) =>
      p == parentOf(p) && (p.endsWith('\\') || p.endsWith('/'));

  /// 列出 [dirPath] 下的受支持图片（直接子文件，自然排序；
  /// 跳过点开头隐藏文件与库中 [hidden] 记录）。
  /// 返回条目的 path 统一用规范化目录 + 平台分隔符拼接。
  static Future<List<ImageEntry>> listImages(String dirPath,
      {Set<String> hidden = const {}}) async {
    final dir = Directory(normalize(dirPath));
    if (await dir.exists().catchError((_) => false)) {
      final out = <ImageEntry>[];
      List<FileSystemEntity> children;
      try {
        children = await dir.list(followLinks: false).toList();
      } catch (_) {
        return const []; // 无权限等 IO 异常按空处理
      }
      for (final e in children) {
        if (e is! File) continue;
        final base = nameOf(e.path);
        if (base.startsWith('.')) continue;
        if (!SupportedFormats.isSupported(e.path)) continue;
        final path = '${dir.path}${Platform.pathSeparator}$base';
        if (hidden.contains(path)) continue;
        try {
          final st = await e.stat();
          out.add(ImageEntry(
            path: path,
            name: base,
            sizeBytes: st.size,
            mtimeMs: st.modified.millisecondsSinceEpoch,
          ));
        } catch (_) {/* 文件刚好消失 */}
      }
      out.sort((a, b) => naturalCompare(a.name, b.name));
      return out;
    }
    return const [];
  }

  /// [dirPath] 所在父目录下含图片的文件夹（自然排序，含 [dirPath] 自身；
  /// 根目录没有同级，返回仅含自身）。跳过点开头目录。
  static Future<List<String>> imageFoldersAround(String dirPath) async {
    final current = normalize(dirPath);
    final parent = parentOf(current);
    if (_isRoot(parent)) return [current];
    final folders = <String>[];
    List<FileSystemEntity> children;
    try {
      children = await Directory(parent).list(followLinks: false).toList();
    } catch (_) {
      return [current];
    }
    for (final e in children) {
      if (e is! Directory) continue;
      final base = nameOf(e.path);
      if (base.startsWith('.')) continue;
      folders.add(normalize(e.path));
    }
    folders.sort((a, b) => naturalCompare(nameOf(a), nameOf(b)));
    // 只保留含图片的文件夹（直接子级，与浏览口径一致）
    final withImages = <String>[];
    for (final f in folders) {
      if (await listImages(f).then((l) => l.isNotEmpty)) withImages.add(f);
    }
    if (!withImages.contains(current)) withImages.add(current);
    withImages.sort((a, b) => naturalCompare(nameOf(a), nameOf(b)));
    return withImages;
  }
}

/// 纯函数（可单测）：[ordered] 为自然排序的文件夹序列（含 current），
/// 返回 current 相邻的前/后一个；越界或不含 current 返回 null。
String? neighborImageFolder(
    List<String> ordered, String current, {required bool forward}) {
  final i = ordered.indexOf(FolderBrowser.normalize(current));
  if (i < 0) return null;
  final t = forward ? i + 1 : i - 1;
  if (t < 0 || t >= ordered.length) return null;
  return ordered[t];
}
