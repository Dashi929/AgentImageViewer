/// 图库索引（library.json）与监控文件夹管理（设计书 3.5 表 3-3）。
library;

import 'dart:io';

import 'json_store.dart';
import '../scanner.dart';

class LibraryIndex {
  LibraryIndex(this._store);

  final JsonStore _store;

  /// 底层 JSON 存储（编辑栈等共用同一数据目录）。
  JsonStore get store => _store;
  final Map<String, ImageEntry> _byPath = {};
  final List<String> _folders = [];

  /// 「从图库移除」的路径（虚拟删除：本地文件不动，重扫不再收录）。
  final Set<String> _hidden = {};
  bool _loaded = false;
  bool _dirty = false;

  List<ImageEntry> get entries {
    final list = _byPath.values.toList()
      ..sort((a, b) => naturalCompare(a.name, b.name));
    return list;
  }

  List<String> get folders => List.unmodifiable(_folders);

  /// 「从图库移除」的路径集合（即时浏览扫描时继续跳过这些历史隐藏项）。
  Set<String> get hiddenPaths => Set.unmodifiable(_hidden);

  ImageEntry? entryAt(String path) => _byPath[path];

  /// 若库中没有 [path] 则按文件现状登记一条（AI 打标/虚拟重命名
  /// 对任意浏览图片生效，不再要求先进图库）。
  /// 文件不存在返回 null。
  ImageEntry? ensureEntry(String path) {
    final existing = _byPath[path];
    if (existing != null) return existing;
    final f = File(path);
    if (!f.existsSync()) return null;
    final st = f.statSync();
    final entry = ImageEntry(
      path: path,
      name: path.split(Platform.pathSeparator).last,
      sizeBytes: st.size,
      mtimeMs: st.modified.millisecondsSinceEpoch,
    );
    upsert(entry);
    return entry;
  }

  Future<void> load() async {
    final data = await _store.load('library.json');
    _byPath.clear();
    _folders.clear();
    if (data != null) {
      _folders.addAll((data['folders'] as List? ?? []).cast<String>());
      _hidden.addAll((data['hidden'] as List? ?? []).cast<String>());
      for (final e in (data['items'] as List? ?? [])) {
        final entry = ImageEntry.fromJson((e as Map).cast<String, Object?>());
        _byPath[entry.path] = entry;
      }
    }
    _loaded = true;
  }

  Future<void> _persist() => _store.save('library.json', {
        'version': 1,
        'folders': _folders,
        'hidden': _hidden.toList(),
        'items': [for (final e in _byPath.values) e.toJson()],
      });

  Future<void> addFolder(String path) async {
    if (!_loaded) await load();
    if (!_folders.contains(path)) _folders.add(path);
    _dirty = true;
  }

  Future<void> removeFolder(String path) async {
    if (!_loaded) await load();
    _folders.remove(path);
    _byPath.removeWhere((p, _) => p.startsWith(path));
    _dirty = true;
  }

  void upsert(ImageEntry e) {
    _byPath[e.path] = e;
    _dirty = true;
  }

  void upsertAll(Iterable<ImageEntry> list) {
    for (final e in list) {
      _byPath[e.path] = e;
    }
    _dirty = true;
  }

  /// 扫描所有监控文件夹并合并进索引，随后落盘。
  /// 清理已消失的文件条目（仅限监控文件夹内；外部登记的文件保留，由 stat 失败时惰性剔除）。
  /// 「从图库移除」的路径不再收录。
  Future<List<ImageEntry>> rescan() async {
    if (!_loaded) await load();
    for (final f in _folders) {
      await scanFolderInto(f);
    }
    for (final f in _folders) {
      _byPath.removeWhere((p, _) =>
          p.startsWith(f) &&
          !(File(p).existsSync() || Directory(p).existsSync()));
    }
    await flush();
    return entries;
  }

  /// 扫描 [folder] 并合并索引（跳过已「从图库移除」的路径），随后落盘。
  /// 返回本次实际入库的条目。
  Future<List<ImageEntry>> scanFolderInto(String folder) async {
    if (!_loaded) await load();
    final visible =
        (await scanDirectory(folder)).where((e) => !_hidden.contains(e.path));
    upsertAll(visible);
    await flush();
    return visible.toList();
  }

  // ---------- 虚拟操作（与 AI 共用同一套记录，设计书 2.5） ----------

  /// 从图库移除条目（虚拟删除）：本地文件不动，重扫不再收录。
  void hideEntry(String path) {
    final removed = _byPath.remove(path) != null;
    final marked = _hidden.add(path);
    if (removed || marked) {
      _dirty = true;
    }
  }

  /// 是否已被「从图库移除」。
  bool isHidden(String path) => _hidden.contains(path);

  void toggleFavorite(String path) {
    final e = _byPath[path];
    if (e != null) {
      e.favorite = !e.favorite;
      _dirty = true;
    }
  }

  void addTag(String path, String tag) {
    final e = _byPath[path];
    if (e != null && tag.isNotEmpty && !e.tags.contains(tag)) {
      e.tags.add(tag);
      _dirty = true;
    }
  }

  void removeTag(String path, String tag) {
    _byPath[path]?.tags.remove(tag);
    _dirty = true;
  }

  void setVirtualName(String path, String? name) {
    _byPath[path]?.virtualName = name;
    _dirty = true;
  }

  void setCategory(String path, String? category) {
    _byPath[path]?.category = category;
    _dirty = true;
  }

  /// 全部标签（标签页导航用）。
  List<String> get allTags {
    final s = <String>{};
    for (final e in _byPath.values) {
      s.addAll(e.tags);
    }
    final list = s.toList()..sort(naturalCompare);
    return list;
  }

  /// 多条件搜索：空格分隔，文件名/虚拟名/标签/文件夹均可命中。
  /// 传 [inList] 时只在该范围内搜（即时浏览：当前文件夹）。
  List<ImageEntry> search(String query, {List<ImageEntry>? inList}) {
    final base = inList ?? entries;
    final q = query.trim();
    if (q.isEmpty) return base;
    final terms = q.toLowerCase().split(RegExp(r'\s+'));
    return base.where((e) {
      final hay =
          '${e.name} ${e.displayName} ${e.tags.join(' ')} ${e.path}'.toLowerCase();
      return terms.every(hay.contains);
    }).toList();
  }

  /// 只写盘，dirty 时才真正 IO。
  Future<void> flush() async {
    if (!_dirty) return;
    await _persist();
    _dirty = false;
  }
}
