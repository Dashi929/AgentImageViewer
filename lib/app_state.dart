/// 应用状态：路径、图库、解码管理器与全局导航（对照参考工程 app_state.dart）。
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

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
    final state = AppState._(
      dataDir: dataDir,
      library: library,
      images: ImageManager(thumbCacheDir: thumbs),
    );
    return state;
  }

  /// 添加监控文件夹并立即扫描入库。
  Future<List<ImageEntry>> addFolder(String path) async {
    await library.addFolder(path);
    final entries = await scanDirectory(path);
    library.upsertAll(entries);
    await library.flush();
    return entries;
  }

  Future<void> rescan() async {
    await library.rescan();
  }

  /// 共享 JsonStore（编辑栈等持久化用）。
  JsonStore get store => library.store;

  /// 标签页 → 图库的搜索词传递。
  final pendingSearch = ValueNotifier<String>('');
  void pendGallerySearch(String q) => pendingSearch.value = q;

  /// 图库数据（标签/收藏等）变更后的公开刷新入口。
  void refreshGallery() => notifyListeners();

  @override
  void dispose() {
    images.dispose();
    super.dispose();
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

/// 全局导航（图库↔浏览视图切换）。
enum NavTab { gallery, tags, ai, settings }

class NavigatorStateEx {
  NavigatorStateEx._();
  static final currentTab = ValueNotifier<NavTab>(NavTab.gallery);

  /// 浏览视图当前打开的文件序列与起点；null 表示未在浏览。
  static final ValueNotifier<({List<ImageEntry> list, int index})?> viewer =
      ValueNotifier(null);

  static void openViewer(List<ImageEntry> list, int index) =>
      viewer.value = (list: list, index: index.clamp(0, list.length - 1));

  static void closeViewer() => viewer.value = null;

  /// 编辑视图当前条目；null 表示未在编辑。
  static final ValueNotifier<ImageEntry?> editor = ValueNotifier(null);


}
