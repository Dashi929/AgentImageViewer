/// 图库视图（设计书 4.3.1）：顶部工具栏 + 元信息行 + 缩略图网格。
library;

import 'dart:io' show Directory;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/image/image_manager.dart';
import '../../core/scanner.dart';
import '../theme.dart';

class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  String _query = '';
  bool _scanning = false;

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final entries = _filter(state.library.entries);
    final folders = state.library.folders;

    return Column(
      children: [
        _Toolbar(
          query: _query,
          onQuery: (q) => setState(() => _query = q),
          onAddFolder: () async {
            final picked = await _pickFolder();
            if (picked == null) return;
            setState(() => _scanning = true);
            await state.addFolder(picked);
            if (mounted) setState(() => _scanning = false);
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              Text(
                '${entries.length} 张图片'
                '${folders.isEmpty ? '' : ' · ${folders.length} 个文件夹'}',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
              if (_scanning) ...[
                const SizedBox(width: 10),
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 6),
                const Text('扫描中…',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
              ],
            ],
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? _EmptyState(
                  isEmptyLibrary: folders.isEmpty && !_scanning,
                  onAddFolder: _scanning
                      ? null
                      : () async {
                          final picked = await _pickFolder();
                          if (picked != null) {
                            setState(() => _scanning = true);
                            await state.addFolder(picked);
                            if (mounted) setState(() => _scanning = false);
                          }
                        },
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220,
                    childAspectRatio: 0.82,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                  ),
                  itemCount: entries.length,
                  itemBuilder: (context, i) => _ThumbCard(
                    entry: entries[i],
                    onOpen: () => NavigatorStateEx.openViewer(entries, i),
                  ),
                ),
        ),
      ],
    );
  }

  List<ImageEntry> _filter(List<ImageEntry> list) {
    final q = _query.trim();
    if (q.isEmpty) return list;
    final terms = q.toLowerCase().split(RegExp(r'\s+'));
    return list.where((e) {
      final hay = '${e.name} ${e.path}'.toLowerCase();
      return terms.every(hay.contains);
    }).toList();
  }

  Future<String?> _pickFolder() async {
    // S1：无 file_selector 依赖，先用文本输入兜底；S3 换系统目录选择器。
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加监控文件夹'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: r'例如 E:\Pictures'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty || !Directory(result).existsSync()) {
      return null;
    }
    return result;
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.query, required this.onQuery, required this.onAddFolder});

  final String query;
  final ValueChanged<String> onQuery;
  final VoidCallback onAddFolder;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              onChanged: onQuery,
              controller: TextEditingController(text: query),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: '搜索文件名 / 路径（空格分隔多条件）',
              ),
            ),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: onAddFolder,
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            label: const Text('添加文件夹'),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: null, // AI 整理 S4 落地
            icon: Icon(Icons.auto_awesome_outlined,
                size: 18, color: AppColors.aiAccent),
            label: Text('AI 整理',
                style: TextStyle(color: AppColors.aiAccent.withValues(alpha: 0.5))),
          ),
        ],
      ),
    );
  }
}

class _ThumbCard extends StatefulWidget {
  const _ThumbCard({required this.entry, required this.onOpen});

  final ImageEntry entry;
  final VoidCallback onOpen;

  @override
  State<_ThumbCard> createState() => _ThumbCardState();
}

class _ThumbCardState extends State<_ThumbCard> {
  Future<_ThumbData>? _future;
  ImageManager? _mgr;
  String? _pinnedKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void didUpdateWidget(covariant _ThumbCard old) {
    super.didUpdateWidget(old);
    if (old.entry.path != widget.entry.path) _load();
  }

  void _load() {
    final state = AppStateScope.of(context);
    _mgr = state.images;
    final e = widget.entry;
    _future = state.images.decode(e.path, e.mtimeMs, target: 320).then((d) {
      state.images.pin(d.cacheKey);
      _pinnedKey = d.cacheKey;
      if (e.width == null && d.width > 0) {
        e.width = d.width;
        e.height = d.height;
      }
      return _ThumbData(d.image, d.width, d.height);
    });
  }

  @override
  void dispose() {
    final k = _pinnedKey;
    if (k != null) _mgr?.unpin(k);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: FutureBuilder<_ThumbData>(
                future: _future,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return const ColoredBox(
                      color: Color(0xFF2A2E36),
                      child: Center(
                          child: Icon(Icons.broken_image_outlined,
                              color: AppColors.textSecondary)),
                    );
                  }
                  final d = snap.data;
                  if (d == null) {
                    // 加载态：主题色渐变占位（4.4 节）
                    return const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF1D2026), Color(0xFF23272F)],
                        ),
                      ),
                    );
                  }
                  return FittedBox(
                    fit: BoxFit.contain,
                    child: RawImage(
                      image: d.image,
                      width: d.w.toDouble(),
                      height: d.h.toDouble(),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
              child: Text(
                widget.entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThumbData {
  const _ThumbData(this.image, this.w, this.h);
  final ui.Image image;
  final int w, h;
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.isEmptyLibrary, this.onAddFolder});

  final bool isEmptyLibrary;
  final VoidCallback? onAddFolder;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.photo_library_outlined,
              size: 48, color: AppColors.textSecondary),
          const SizedBox(height: 12),
          Text(
            isEmptyLibrary ? '添加一个文件夹，开始浏览你的图库' : '没有匹配的图片',
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          if (isEmptyLibrary) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAddFolder,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加文件夹'),
            ),
          ],
        ],
      ),
    );
  }
}
