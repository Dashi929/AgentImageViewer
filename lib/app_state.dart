/// 应用状态：数据目录、本地库（AI 虚拟操作用）、解码管理器与全局导航。
///
/// v0.5 即时浏览改造：图库（扫描入库/监控文件夹）已移除，
/// 打开即按「所在文件夹」浏览。
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'core/browser/folder_browser.dart';
import 'core/db/json_store.dart';
import 'core/db/library.dart';
import 'core/image/image_manager.dart';
import 'core/scanner.dart';


class AppState extends ChangeNotifier {
  AppState._({
    required this.dataDir,
    required this.library,
    required this.images,
  });

  final Directory dataDir;
  final LibraryIndex library;
  final ImageManager images;

  /// 异步初始化（桌面 userData / 移动沙盒，由 path_provider 决定）。
  static Future<AppState> create() async {
    final support = await getApplicationSupportDirectory();
    final dataDir = Directory('${support.path}${Platform.pathSeparator}data');
    await dataDir.create(recursive: true);
    final store = JsonStore(baseDir: dataDir);
    final library = LibraryIndex(store);
    await library.load();
    final thumbs = Directory('${dataDir.path}${Platform.pathSeparator}cache'
        '${Platform.pathSeparator}thumbs');
    return AppState._(
      dataDir: dataDir,
      library: library,
      images: ImageManager(thumbCacheDir: thumbs),
    );
  }

  /// 测试专用构造（绕过 path_provider）。
  @visibleForTesting
  factory AppState.forTest(Directory dataDir) {
    final store = JsonStore(baseDir: dataDir);
    final library = LibraryIndex(store);
    final thumbs = Directory(
        '${dataDir.path}${Platform.pathSeparator}cache'
        '${Platform.pathSeparator}thumbs');
    return AppState._(
      dataDir: dataDir,
      library: library,
      images: ImageManager(thumbCacheDir: thumbs),
    );
  }

  /// 共享 JsonStore（编辑栈等持久化用）。
  JsonStore get store => library.store;

  int _aiRunning = 0;

  /// AI 任务（会话/批量队列）是否运行中——关窗确认依据（设计书 3.7）。
  bool get aiBusy => _aiRunning > 0;

  void aiStart() => _aiRunning++;
  void aiEnd() {
    _aiRunning = (_aiRunning - 1).clamp(0, 1 << 30);
    notifyListeners();
  }

  /// 打开单张图片（首页/外部双击）：按其所在文件夹建立浏览序列并定位到该图。
  /// 返回错误文案；null 表示成功。
  Future<String?> openFile(String path) async {
    final normalized = FolderBrowser.normalize(path);
    if (!File(normalized).existsSync()) return '文件不存在：$path';
    final folder = FolderBrowser.parentOf(normalized);
    final list = await FolderBrowser.listImages(folder,
        hidden: library.hiddenPaths);
    if (list.isEmpty) {
      final e = await _entryFromFile(normalized);
      if (e == null) return '文件不存在：$path';
      NavigatorStateEx.openViewer([e], 0);
      return null;
    }
    final idx = list.indexWhere((e) => e.path == normalized);
    NavigatorStateEx.openViewer(list, idx < 0 ? 0 : idx);
    return null;
  }

  /// 打开文件夹（首页）：列出文件夹内图片进入浏览。返回错误文案；null 成功。
  Future<String?> openFolder(String path) async {
    final list = await FolderBrowser.listImages(FolderBrowser.normalize(path),
        hidden: library.hiddenPaths);
    if (list.isEmpty) return '该文件夹没有可显示的图片';
    NavigatorStateEx.openViewer(list, 0);
    return null;
  }

  /// 外部双击打开的图片：直接进入所在文件夹浏览（设计书 6.1）。
  Future<void> registerExternalOpen(String path) => openFile(path);

  @override
  void dispose() {
    images.dispose();
    super.dispose();
  }

  static Future<ImageEntry?> _entryFromFile(String path) async {
    final f = File(path);
    if (!await f.exists()) return null;
    final st = await f.stat();
    return ImageEntry(
      path: path,
      name: FolderBrowser.nameOf(path),
      sizeBytes: st.size,
      mtimeMs: st.modified.millisecondsSinceEpoch,
    );
  }
}

/// InheritedNotifier 桥：UI 层读取 AppState。
class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({super.key, required AppState state, required super.child})
      : super(notifier: state);

  static AppState of(BuildContext context, {bool listen = true}) {
    final w = listen
        ? context.dependOnInheritedWidgetOfExactType<AppStateScope>()
        : context.getInheritedWidgetOfExactType<AppStateScope>();
    return w!.notifier!;
  }
}

/// 全局导航（主页 ↔ 浏览视图切换）。
enum NavTab { home, ai, settings }

class NavigatorStateEx {
  NavigatorStateEx._();
  static final currentTab = ValueNotifier<NavTab>(NavTab.home);

  /// 浏览视图当前打开的文件序列与起点；null 表示未在浏览。
  static final ValueNotifier<({List<ImageEntry> list, int index})?> viewer =
      ValueNotifier(null);

  static void openViewer(List<ImageEntry> list, int index) =>
      viewer.value = (list: list, index: index.clamp(0, list.length - 1));

  static void closeViewer() {
    viewer.value = null;
    currentTab.value = NavTab.home;
  }

  /// 编辑视图当前条目；null 表示未在编辑。
  static final ValueNotifier<ImageEntry?> editor = ValueNotifier(null);


}
