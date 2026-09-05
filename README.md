# AgentImageViewer

跨平台 AI 图片浏览器：快如原生的看图器、够用的轻量编辑器、会自己动手的 AI 图片助手。四端（Windows / Linux / Android / iOS）共用一份 Flutter 代码，图像处理统一走 **Filter Pipeline** 架构。

- 设计依据：《AgentImageViewer-设计文档-完整版v2.docx》
- 开发流程：[开发流程.md](开发流程.md)（S0 奠基 → S1 浏览内核 → S2 编辑/图库 → S3 v0.1 发布 → S4 AI Agent → S5 桌面双端 → S6 移动端 → S7 全平台）
- 参考：AgentVideoPlayer 系列同源工程

## 架构

```
lib/
├── core/               # 纯 Dart 核心，可单测
│   ├── pipeline/       # Filter Pipeline：node（节点与校验）/ pipeline（历史栈）/ source（tile、LRU、缓存键）
│   ├── db/             # JSON 原子落盘（library / edits / settings）
│   ├── scanner.dart    # 图库扫描（S1）
│   └── ai/             # OpenAI 兼容客户端、Agent 工具、串行队列（S4）
├── ui/                 # 深色主题界面（表 4-1 色板）
└── platform/           # 平台通道：文件关联/回收站/托盘/相册（S5/S6）
```

浏览态 = `Source → RenderSink`（零 Filter 节点的最快路径）；编辑态 = 完整节点链实时求值；导出 = `ExportSink` 一次性合成。节点参数即设计书 3.4 节操作栈 JSON，坐标一律 0~1 相对比例。

## 开发

```bash
flutter pub get
flutter analyze   # 零告警基线
flutter test      # core 层自动化测试
python tool/gen_bench_images.py && AIV_BENCH=1 flutter test test/bench_test.dart  # 性能基准（本地）
flutter run -d windows
```

CI：`.github/workflows/ci.yml`（analyze + test，Ubuntu/Windows 双矩阵）。

## 版本

| 版本 | 范围 | 状态 |
|---|---|---|
| v0.1 MVP | Windows：浏览 + 编辑 + 图库 + 设置 | ✅ tag v0.1.0 |
| v0.2 | AI Agent（七工具决议循环 + 确认卡片 + 串行队列） | ✅ 完成 |
| v0.3 | Windows 文件关联(HKCU) + 单实例外部打开 + 回收站 | ✅ 完成；托盘/壁纸/Linux 打包待做 |
| v0.4 | 移动端：底部标签栏/两列网格/手势集/生命周期 | ✅ Android APK 构建通过；iOS 待真机验证 |
| v1.0 | 四端一致性收尾、iOS 上架 | 未开始 |

自动化测试：76 项（pipeline/求值引擎/编辑器/扫描/EXIF/图库/AI 客户端/Agent 循环/队列/平台命令），CI 双平台矩阵。
