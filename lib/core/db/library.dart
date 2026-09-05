/// 图库索引（library.json）与监控文件夹管理（设计书 3.5 表 3-3）。
library;

import 'dart:io';

import 'json_store.dart';
import '../scanner.dart';

class LibraryIndex {
  LibraryIndex(this._store);

  final JsonStore _store;
  final Map<String, ImageEntry> _byPath = {};
  final List<String> _folders = [];
  bool _loaded = false;
  bool _dirty = false;

  List<ImageEntry> get entries {
    final list = _byPath.values.toList()
      ..sort((a, b) => naturalCompare(a.name, b.name));
    return list;
  }

  List<String> get folders => List.unmodifiable(_folders);
  ImageEntry? entryAt(String path) => _byPath[path];

  Future<void> load() async {
    final data = await _store.load('library.json');
    _byPath.clear();
    _folders.clear();
    if (data != null) {
      _folders.addAll((data['folders'] as List? ?? []).cast<String>());
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
  Future<List<ImageEntry>> rescan() async {
    if (!_loaded) await load();
    for (final f in _folders) {
      upsertAll(await scanDirectory(f));
    }
    for (final f in _folders) {
      _byPath.removeWhere((p, _) =>
          p.startsWith(f) &&
          !(File(p).existsSync() || Directory(p).existsSync()));
    }
    await flush();
    return entries;
  }

  /// 只写盘，dirty 时才真正 IO。
  Future<void> flush() async {
    if (!_dirty) return;
    await _persist();
    _dirty = false;
  }
}
