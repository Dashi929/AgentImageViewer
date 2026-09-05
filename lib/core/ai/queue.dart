/// AI 任务串行队列（设计书 3.7）：逐项容错，单张失败不中断批次，
/// 结束后汇报成功与失败清单，失败项可单独重试。
library;

import 'dart:async';

enum TaskStatus { pending, running, success, failed }

class TaskItem<T> {
  TaskItem(this.id, this.label, this.run);

  final String id;
  final String label;
  final Future<T> Function() run;

  TaskStatus status = TaskStatus.pending;
  Object? error;
  T? result;
}

class AiTask<T> {
  AiTask(this.title, List<TaskItem<T>> items) : _items = items;

  final String title;
  final List<TaskItem<T>> _items;
  final _progress = StreamController<AiTask>.broadcast();

  List<TaskItem<T>> get items => List.unmodifiable(_items);
  Stream<AiTask> get onProgress => _progress.stream;

  int get doneCount =>
      _items.where((i) => i.status == TaskStatus.success || i.status == TaskStatus.failed).length;
  int get successCount => _items.where((i) => i.status == TaskStatus.success).length;
  int get failedCount => _items.where((i) => i.status == TaskStatus.failed).length;
  bool get isFinished => doneCount == _items.length;
  List<TaskItem<T>> get failedItems =>
      _items.where((i) => i.status == TaskStatus.failed).toList();

  /// 串行执行；单张失败不中断（catch 后继续）。
  Future<AiTask<T>> run() async {
    for (final item in _items) {
      if (item.status == TaskStatus.success) continue;
      item.status = TaskStatus.running;
      _progress.add(this);
      try {
        item.result = await item.run();
        item.status = TaskStatus.success;
      } catch (e) {
        item.error = e;
        item.status = TaskStatus.failed;
      }
      _progress.add(this);
    }
    _progress.add(this);
    return this;
  }

  /// 只重跑失败项。
  Future<AiTask<T>> retryFailed() async {
    for (final item in _items) {
      if (item.status == TaskStatus.failed) item.status = TaskStatus.pending;
    }
    return run();
  }

  /// 汇总文案：如「已识别 36/120，失败 2」。
  String summary() => '$doneCount/${_items.length}，失败 $failedCount';

  void dispose() => _progress.close();
}
