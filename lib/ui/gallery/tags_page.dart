/// 标签页（设计书 4.2 底部标签栏之一）：按标签聚合浏览。
library;

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../theme.dart';

class TagsPage extends StatelessWidget {
  const TagsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final tags = app.library.allTags;
        if (tags.isEmpty) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.label_outline, size: 48, color: AppColors.textSecondary),
                SizedBox(height: 12),
                Text('还没有标签。可在图库卡片右键添加，或交给 AI 批量打标。',
                    style: TextStyle(color: AppColors.textSecondary)),
              ],
            ),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 240,
            mainAxisExtent: 64,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
          ),
          itemCount: tags.length,
          itemBuilder: (context, i) {
            final tag = tags[i];
            final count = app.library.entries.where((e) => e.tags.contains(tag)).length;
            return Card(
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  NavigatorStateEx.currentTab.value = NavTab.gallery;
                  // 把标签作为搜索条件带入图库
                  app.pendGallerySearch(tag);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      const Icon(Icons.label_outline, size: 18, color: AppColors.aiAccent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(tag,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13)),
                      ),
                      Text('$count',
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
