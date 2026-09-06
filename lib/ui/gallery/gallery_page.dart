/// 图库视图（设计书 4.3.1）：顶部工具栏 + 元信息行 + 缩略图网格。
library;

import 'dart:io' show Directory, Platform, Process;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_state.dart';
import '../../core/image/image_manager.dart';
import '../../core/image/heic_support.dart';
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
  _GalleryFilter _filter = _GalleryFilter.all;
  String? _folderFilter; // 文件夹维度：指定监控目录
  GallerySort _sort = GallerySort.name;

  void _osd(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(msg, style: const TextStyle(fontSize: 13))));
  }
  bool get _mobile =>
      !const bool.fromEnvironment('dart.library.js_util') &&
      (Platform.isAndroid || Platform.isIOS);

  @override
  Widget build(BuildContext context) {
    final state = AppStateScope.of(context);
    final entries = _applyFilter(state.library.entries);
    final folders = state.library.folders;

    return Column(
      children: [
        _Toolbar(
          query: _query,
          onQuery: (q) => setState(() => _query = q),
          onAddFolder: () async {
            final picked = await _pickFolder();
            if (picked == null) return;
            if (Platform.isAndroid || Platform.isIOS) {
              final st = await _ensureMediaPermission();
              if (!st) {
                _osd('未获得相册读取权限，请在系统设置中授权后重试');
                return;
              }
            }
            setState(() => _scanning = true);
            await state.addFolder(picked);
            if (mounted) setState(() => _scanning = false);
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(
            children: [
              for (final f in _GalleryFilter.values)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(_filterLabel(f, _folderFilter),
                        style: const TextStyle(fontSize: 12)),
                    selected: _filter == f,
                    onSelected: (_) => setState(() {
                      _filter = f;
                      if (f == _GalleryFilter.folder && _folderFilter == null) {
                        _folderFilter = folders.isNotEmpty ? folders.first : null;
                      }
                    }),
                  ),
                ),
              const Spacer(),
              // 排序方式：点击循环（设计书 4.3.1 元信息行）
              InkWell(
                onTap: () => setState(() {
                  final vals = GallerySort.values;
                  _sort = vals[(vals.indexOf(_sort) + 1) % vals.length];
                }),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${entries.length} 张 · ${_sortLabel(_sort)}',
                          style: const TextStyle(
                              color: AppColors.textSecondary, fontSize: 12)),
                      const Icon(Icons.sort, size: 14,
                          color: AppColors.textSecondary),
                    ],
                  ),
                ),
              ),
              if (_scanning) ...[
                const SizedBox(width: 10),
                const SizedBox(
                    width: 12, height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ],
          ),
        ),
        if (_filter == _GalleryFilter.folder && folders.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: DropdownButton<String>(
                value:
                    folders.contains(_folderFilter) ? _folderFilter : folders.first,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: [
                  for (final f in folders)
                    DropdownMenuItem(
                        value: f,
                        child: Text(f,
                            style: const TextStyle(fontSize: 11),
                            overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() => _folderFilter = v),
              ),
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
              : _filter == _GalleryFilter.time
                  ? _TimeGroupedGrid(entries: entries, mobile: _mobile)
                  : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _mobile ? 2 : 4, // 移动端两列（4.5 节）
                    childAspectRatio: 0.82,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                  ),
                  itemCount: entries.length,
                  itemBuilder: (context, i) => _ThumbCard(
                    key: ValueKey(entries[i].path),
                    entry: entries[i],
                    onOpen: () => NavigatorStateEx.openViewer(entries, i),
                  ),
                ),
        ),
      ],
    );
  }

  List<ImageEntry> _applyFilter(List<ImageEntry> list) {
    final state = AppStateScope.of(context);
    var out = state.library.search(_query);
    switch (_filter) {
      case _GalleryFilter.all:
        break;
      case _GalleryFilter.fav:
        out = out.where((e) => e.favorite).toList();
      case _GalleryFilter.folder:
        if (_folderFilter != null) {
          out = out.where((e) => e.path.startsWith(_folderFilter!)).toList();
        }
      case _GalleryFilter.time:
        break; // 时间维度在分组呈现，不剔除
    }
    out.sort((a, b) => compareEntries(a, b, _sort));
    return out;
  }

  Future<bool> _ensureMediaPermission() async {
    if (Platform.isAndroid) {
      var st = await Permission.photos.request();
      if (!st.isGranted) st = await Permission.storage.request();
      return st.isGranted;
    }
    if (Platform.isIOS) return (await Permission.photos.request()).isGranted;
    return true;
  }

  Future<String?> _pickFolder() async {
    // 移动端预填常见媒体目录；桌面为文本输入（后续里程碑换系统目录选择器）。
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加监控文件夹'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: Platform.isAndroid || Platform.isIOS
                ? '/storage/emulated/0/Pictures'
                : r'例如 E:\Pictures',
          ),
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
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: MediaQuery.of(context).size.width - 32),
          child: Row(
        children: [
          SizedBox(
            width: 280,
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
        ),
      ),
    );
  }
}

class _ThumbCard extends StatefulWidget {
  const _ThumbCard({super.key, required this.entry, required this.onOpen});

  final ImageEntry entry;
  final VoidCallback onOpen;

  @override
  State<_ThumbCard> createState() => _ThumbCardState();
}

class _ThumbCardState extends State<_ThumbCard> {
  Future<_ThumbData>? _future;
  ImageManager? _mgr;
  String? _pinnedKey;

  void _osd(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(msg, style: const TextStyle(fontSize: 13))));
  }

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
    _future = state.images
        .decode(e.path, e.mtimeMs, target: 320, autoPin: true)
        .then((d) {
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
        onSecondaryTapUp: (d) => _showContextMenu(context, d.globalPosition),
        onLongPress: () {
          // 移动端长按呼出同一套菜单（设计书 5.2/5.4）
          if (Platform.isAndroid || Platform.isIOS) {
            _showContextMenu(context, const Offset(80, 200));
          }
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FutureBuilder<_ThumbData>(
                future: _future,
                builder: (context, snap) {
                  if (snap.hasError) {
                    final ext = SupportedFormats.pathExtension(widget.entry.path);
                    final isHeic = ext == '.heic' || ext == '.heif';
                    return ColoredBox(
                      color: const Color(0xFF2A2E36),
                      child: InkWell(
                        onTap: isHeic
                            ? () => showHeicGuidance(context)
                            : null,
                        child: Center(
                          child: Icon(
                            isHeic
                                ? Icons.help_outline
                                : Icons.broken_image_outlined,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
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
                  // 等比适应卡片（不拉伸）：contain 于卡片缩略区
                  return RawImage(
                    image: d.image,
                    fit: BoxFit.contain,
                    width: double.infinity,
                    height: double.infinity,
                  );
                  },
                ),
                if (widget.entry.favorite)
                  const Positioned(
                    top: 6,
                    right: 6,
                    child: Icon(Icons.star, size: 16, color: Colors.amber),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.entry.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textPrimary),
                    ),
                  ),
                  for (final tag in widget.entry.tags.take(2))
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(
                        tag,
                        style: const TextStyle(
                            fontSize: 10,
                            color: AppColors.aiAccent,
                            backgroundColor: Color(0x1A8B7CF6)),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 右键菜单（设计书 5.4 表 5-4；移动端长按复用，隐藏桌面专属项）
  void _showContextMenu(BuildContext context, Offset pos) {
    final app = AppStateScope.of(context, listen: false);
    final e = widget.entry;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      items: [
        const PopupMenuItem(value: 'open', child: Text('打开')),
        const PopupMenuItem(value: 'edit', child: Text('编辑')),
        const PopupMenuItem(value: 'ai', enabled: false, child: Text('AI 识别此图')),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'fav',
          child: Text(e.favorite ? '取消收藏' : '设为收藏'),
        ),
        const PopupMenuItem(value: 'rename', child: Text('虚拟重命名 (F2)')),
        const PopupMenuItem(value: 'tag', child: Text('添加标签')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'copyPath', child: Text('复制文件路径')),
        const PopupMenuItem(value: 'reveal', child: Text('显示所在文件夹')),
        const PopupMenuItem(value: 'delete', child: Text('从图库删除')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'props', child: Text('属性')),
      ],
    ).then((action) async {
      if (action == null) return;
      switch (action) {
        case 'open':
          widget.onOpen();
        case 'edit':
          NavigatorStateEx.editor.value = e;
        case 'fav':
          app.library.toggleFavorite(e.path);
          await app.library.flush();
        case 'rename':
          if (!context.mounted) return;
          final ctrl = TextEditingController(text: e.virtualName ?? e.name);
          final name = await showDialog<String>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('虚拟重命名（不修改真实文件）'),
              content: TextField(controller: ctrl, autofocus: true),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, ctrl.text),
                    child: const Text('确定')),
              ],
            ),
          );
          if (name != null) {
            app.library.setVirtualName(e.path, name.isEmpty ? null : name);
            await app.library.flush();
          }
        case 'tag':
          if (!context.mounted) return;
          final ctrl = TextEditingController();
          final tag = await showDialog<String>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('添加标签'),
              content: TextField(controller: ctrl, autofocus: true),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, ctrl.text),
                    child: const Text('添加')),
              ],
            ),
          );
          if (tag != null && tag.isNotEmpty) {
            app.library.addTag(e.path, tag);
            await app.library.flush();
          }
        case 'copyPath':
          await Clipboard.setData(ClipboardData(text: e.path));
        case 'delete':
          if (!context.mounted) return;
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('从图库删除'),
              content: const Text('仅从图库移除此图，不删除本地文件。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('删除')),
              ],
            ),
          );
          if (confirmed == true) {
            app.library.hideEntry(e.path);
            await app.library.flush();
            if (context.mounted) _osd('已从图库移除（本地文件保留）');
          }
        case 'reveal':
          if (Platform.isWindows) {
            Process.run('explorer.exe', ['/select,', e.path]);
          } else if (Platform.isLinux) {
            Process.run('xdg-open',
                [e.path.substring(0, e.path.lastIndexOf('/'))]);
          }
        case 'props':
          if (!context.mounted) return;
          showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(e.displayName),
              content: Text(
                  '路径：${e.path}\n'
                  '尺寸：${e.width ?? '?'}×${e.height ?? '?'}\n'
                  '大小：${(e.sizeBytes / 1024).toStringAsFixed(0)} KB\n'
                  '标签：${e.tags.join('、')}\n'
                  '分类：${e.category ?? '-'}'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭')),
              ],
            ),
          );
      }
      app.refreshGallery();
    });
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


/// HEIC 解码失败引导（设计书 2.2：检测缺失时给出引导提示）
Future<void> showHeicGuidance(BuildContext context) async {
  final support = await detectHeicSupport();
  final text = heicGuidanceText(support);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('HEIC 格式提示'),
      content: Text(text.isEmpty ? '该文件无法解码。' : text,
          style: const TextStyle(fontSize: 13)),
      actions: [
        if (support == HeicSupport.missing && Platform.isWindows)
          TextButton(
            onPressed: () => launchUrl(heifStoreUri()),
            child: const Text('打开 Microsoft Store'),
          ),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了')),
      ],
    ),
  );
}

/// 图库四维度组织（设计书 2.5）：全部 / 收藏 / 时间 / 文件夹。
enum _GalleryFilter { all, fav, time, folder }

String _filterLabel(_GalleryFilter f, String? folder) => switch (f) {
      _GalleryFilter.all => '全部',
      _GalleryFilter.fav => '收藏',
      _GalleryFilter.time => '时间',
      _GalleryFilter.folder => folder == null
          ? '文件夹'
          : '文件夹：${folder.split('/').last.split(String.fromCharCode(92)).last}',
    };

String _sortLabel(GallerySort s) => switch (s) {
      GallerySort.name => '名称',
      GallerySort.time => '时间',
      GallerySort.size => '大小',
    };

/// 时间维度：按月分组的网格（设计书 2.5 时间维度组织）。
class _TimeGroupedGrid extends StatelessWidget {
  const _TimeGroupedGrid({required this.entries, required this.mobile});

  final List<ImageEntry> entries;
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final groups = groupByMonth(entries);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: groups.length,
      itemBuilder: (context, gi) {
        final g = groups[gi];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(g.month,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary)),
            ),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: mobile ? 2 : 4,
                childAspectRatio: 0.82,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
              ),
              itemCount: g.items.length,
              itemBuilder: (context, i) => _ThumbCard(
                key: ValueKey(g.items[i].path),
                entry: g.items[i],
                onOpen: () => NavigatorStateEx.openViewer(g.items, i),
              ),
            ),
          ],
        );
      },
    );
  }
}
