/// 图库目录扫描：递归找受支持格式、自然排序（设计书 2.2/2.5 节）。
///
/// 纯 Dart，无 IO 之外的依赖；Directory 访问由调用方注入以便测试。
library;

import 'dart:io';

/// 支持的格式扩展名（设计书 2.2 表 2-2 + 6.2 节）。
abstract final class SupportedFormats {
  /// MVP 完整支持
  static const core = {'.jpg', '.jpeg', '.png', '.bmp'};

  /// 动图
  static const animated = {'.gif', '.webp'};

  /// 完整支持（AVIF 依赖系统解码器）
  static const extended = {'.svg', '.avif', '.ico'};

  /// 视系统而定，不在 MVP 范围
  static const conditional = {'.heic', '.heif'};

  /// 默认扫描范围（svg/ico 解码在 S1 不入浏览管线，扫描仍收录）
  static const all = {...core, ...animated, ...extended, ...conditional};

  static bool isSupported(String path) {
    final ext = pathExtension(path);
    return all.contains(ext);
  }

  static String pathExtension(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return '';
    return path.substring(dot).toLowerCase();
  }
}

/// 自然排序：数字段按数值比较（img2 < img10）。
int naturalCompare(String a, String b) {
  var i = 0, j = 0;
  while (i < a.length && j < b.length) {
    final ca = a.codeUnitAt(i), cb = b.codeUnitAt(j);
    final da = _isDigit(ca), db = _isDigit(cb);
    if (da && db) {
      var ie = i, je = j;
      while (ie < a.length && _isDigit(a.codeUnitAt(ie))) {
        ie++;
      }
      while (je < b.length && _isDigit(b.codeUnitAt(je))) {
        je++;
      }
      final na = int.tryParse(a.substring(i, ie));
      final nb = int.tryParse(b.substring(j, je));
      if (na != null && nb != null && na != nb) return na.compareTo(nb);
      // 数值相等或超长（前导零），退化为字符串段比较
      final cmp = a.substring(i, ie).compareTo(b.substring(j, je));
      if (cmp != 0) return cmp;
      i = ie;
      j = je;
    } else {
      final cmp = _lower(ca).compareTo(_lower(cb));
      if (cmp != 0) return cmp;
      i++;
      j++;
    }
  }
  // 一方耗尽：短者在前；都耗尽则退化为普通比较保证稳定
  if (i >= a.length && j >= b.length) return a.compareTo(b);
  return i >= a.length ? -1 : 1;
}

int _lower(int c) => (c >= 0x41 && c <= 0x5A) ? c + 0x20 : c;
bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// 一张图的索引条目。标签/收藏/分类/虚拟重命名均为虚拟操作，只写本地库。
class ImageEntry {
  ImageEntry({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.mtimeMs,
    this.width,
    this.height,
    List<String>? tags,
    this.favorite = false,
    this.category,
    this.virtualName,
  }) : tags = List.of(tags ?? const []);

  final String path;
  final String name;
  final int sizeBytes;
  final int mtimeMs;
  int? width, height;
  final List<String> tags;
  bool favorite;
  String? category;

  /// 虚拟重命名的显示名（不修改真实文件）。
  String? virtualName;

  String get displayName => (virtualName?.isNotEmpty ?? false) ? virtualName! : name;

  Map<String, Object?> toJson() => {
        'path': path,
        'name': name,
        'size': sizeBytes,
        'mtime': mtimeMs,
        if (width != null) 'w': width,
        if (height != null) 'h': height,
        if (tags.isNotEmpty) 'tags': tags,
        if (favorite) 'fav': true,
        if (category != null) 'cat': category,
        if (virtualName != null) 'vname': virtualName,
      };

  static ImageEntry fromJson(Map<String, Object?> j) => ImageEntry(
        path: j['path'] as String,
        name: j['name'] as String,
        sizeBytes: (j['size'] as num).toInt(),
        mtimeMs: (j['mtime'] as num).toInt(),
        width: (j['w'] as num?)?.toInt(),
        height: (j['h'] as num?)?.toInt(),
        tags: (j['tags'] as List?)?.cast<String>(),
        favorite: j['fav'] as bool? ?? false,
        category: j['cat'] as String?,
        virtualName: j['vname'] as String?,
      );
}

/// 递归扫描目录，返回自然排序的条目。
/// 跳过无权限/不可读目录；隐藏目录（. 开头）跳过。
Future<List<ImageEntry>> scanDirectory(String dirPath, {int depth = 4}) async {
  final out = <ImageEntry>[];
  final root = Directory(dirPath);
  if (!await root.exists()) return out;

  Future<void> walk(Directory dir, int level) async {
    List<FileSystemEntity> children;
    try {
      children = await dir.list(followLinks: false).toList();
    } catch (e) {
      assert(() {
        // ignore: avoid_print
        print('[scanner] list failed: ${dir.path} -> $e');
        return true;
      }());
      return; // 无权限等 IO 异常：跳过该目录
    }
    for (final e in children) {
      final base = e.path.split(Platform.pathSeparator).last;
      if (base.startsWith('.')) continue;
      if (e is File) {
        if (!SupportedFormats.isSupported(e.path)) continue;
        try {
          final st = await e.stat();
          out.add(ImageEntry(
            path: e.path,
            name: base,
            sizeBytes: st.size,
            mtimeMs: st.modified.millisecondsSinceEpoch,
          ));
        } catch (_) {/* 文件刚好消失 */}
      } else if (e is Directory && level < depth) {
        await walk(e, level + 1);
      }
    }
  }

  await walk(root, 0);
  assert(() {
    // ignore: avoid_print
    print('[scanner] scanned ${root.path}: ${out.length} entries');
    return true;
  }());
  out.sort((a, b) => naturalCompare(a.name, b.name));
  return out;
}

/// 图库排序方式（设计书 4.3.1 元信息行）。
enum GallerySort { name, time, size }

/// 按 [sort] 比较两条图库条目（纯函数，可单测）。
int compareEntries(ImageEntry a, ImageEntry b, GallerySort sort) {
  switch (sort) {
    case GallerySort.name:
      return naturalCompare(a.name, b.name);
    case GallerySort.time:
      final c = b.mtimeMs.compareTo(a.mtimeMs); // 新的在前
      return c != 0 ? c : naturalCompare(a.name, b.name);
    case GallerySort.size:
      final c = b.sizeBytes.compareTo(a.sizeBytes); // 大的在前
      return c != 0 ? c : naturalCompare(a.name, b.name);
  }
}

/// 按月份分组（时间维度组织，设计书 2.5）。纯函数，可单测。
List<({String month, List<ImageEntry> items})> groupByMonth(
    List<ImageEntry> entries) {
  final map = <String, List<ImageEntry>>{};
  for (final e in entries) {
    final d = DateTime.fromMillisecondsSinceEpoch(e.mtimeMs);
    final key =
        '${d.year}-${d.month.toString().padLeft(2, '0')}';
    map.putIfAbsent(key, () => []).add(e);
  }
  final keys = map.keys.toList()..sort((a, b) => b.compareTo(a)); // 新月份在前
  return [for (final k in keys) (month: k, items: map[k]!)];
}

/// 生成缩略图任务清单：mtime 变化或无缓存键的条目优先。
List<ImageEntry> pendingThumbTasks(List<ImageEntry> entries, Set<String> cachedKeys,
    String Function(ImageEntry) keyFor) {
  return [for (final e in entries) if (!cachedKeys.contains(keyFor(e))) e];
}
