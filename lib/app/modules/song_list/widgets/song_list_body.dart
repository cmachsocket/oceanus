import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../data/models/song.dart';
import '../controllers/song_list_body_controller.dart';
import 'song_row_tile.dart';

/// 歌曲列表壳:loading / empty / error / 真实列表 四态合一
///
/// **不再接数据 / 回调参数** —— 直接接 [SongListBodyController],widget 内部
/// 读 controller 的 Rx 字段(响应式)+ 调调方法(命令)。
///
/// - 调用方只需 `Get.find<SongListBodyController>()` 拿 controller 传入
/// - 列表渲染走 [SongRowTile],业务侧零硬编码
/// - `extraTrailing` / `onLongPress` / `selectedHighlight` 这三个**仍然接参**,
///   因为它们不是 controller 数据 —— 是 widget 层对 cell 的定制
class SongListBody extends StatelessWidget {
  const SongListBody({
    super.key,
    this.extraTrailing,
    this.selectedHighlight,
    required this.controllerTag,
  });

  /// 歌曲列表 controller
  final String controllerTag;
  // 仍然接参的:这些是 widget 层定制,不是 controller 数据

  /// 为 [SongRowTile] 暴露的额外 trailing widget,同时会传递当前 Song 和 index。
  final Widget Function(Song, int)? extraTrailing;

  /// 当前正在播放的歌曲在列表中的 index(用于高亮)
  final int? selectedHighlight;

  @override
  Widget build(BuildContext context) {
    final SongListBodyController controller = Get.find<SongListBodyController>(
      tag: controllerTag,
    );
    // Obx 包裹整个 build:controller 的 Rx 字段变化触发重建
    return Obx(() {
      final isLoading = controller.isLoading.value;
      final errorMessage = controller.errorMessage.value;
      if (isLoading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (errorMessage != null) {
        final scheme = Theme.of(context).colorScheme;
        return Center(
          child: Text(
            '加载失败: $errorMessage',
            style: TextStyle(color: scheme.error),
          ),
        );
      }
      if (controller.songs.isEmpty) {
        return const Center(child: Text('暂无歌曲'));
      }
      return ListView.builder(
        prototypeItem: const SongRowTile(song: Song.empty()),
        itemCount: controller.songs.length,
        itemBuilder: (context, index) {
          final song = controller.songs[index];
          final selected =
              selectedHighlight != null && index == selectedHighlight;
          return SongRowTile(
            selected: selected,
            song: song,
            onToggleFavorite: () => controller.toggleFavorite(song.id),
            onPlay: () => controller.playSong(song),
            extraTrailing: extraTrailing != null
                ? () => extraTrailing!(song, index)
                : null,
            onLongPress: () => controller.onSongLongPress(song, index),
            // isLiked 内部读 likedIds(Obx),SongRowTile 内部已经包了 Obx
            isLiked: () => controller.isLiked(song.id),
          );
        },
      );
    });
  }
}
