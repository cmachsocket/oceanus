import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../data/models/song.dart';
import '../../song_list/widgets/song_row_tile.dart';
import '../controllers/play_list_controller.dart';
import '../../../core/constants/default_values.dart';

/// 播放列表页 —— 显示当前 AudioPlayerService.playlist(已加载的播放队列)。
///
/// **数据源**:`PlayListController.playlist` getter 转发到 `AudioPlayerService.playlist`
/// (RxList&lt;Song&gt;)。wrapper 是真相源,handler 的 `_onQueue` 流回推时 UI 自动 rebuild。
///
/// **不调后端**:这里是已经存在的 wrapper.playlist,直接渲染即可(所以不复用
/// SongListBody:那要绑 [SongListBodyController],会让 songs 归谁维护变模糊)。
///
/// **架构边界**:AudioPlayerService.playlist 是当前播放队列(handler 维护),
/// PlayListController 是 facade(转 commands 给 wrapper),本页只渲染 + 转发点击事件。
class PlayListPage extends StatelessWidget {
  const PlayListPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<PlayListController>(
      tag: DefaultValues.playlistControllerTag,
    );
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Get.back(),
          icon: const Icon(Icons.arrow_back),
        ),
        title: const Text('播放列表'),
      ),
      body: Obx(() {
        final List<Song> playlist = controller.playlist.toList(growable: false);
        final int currentIndex = controller.currentIndex.value;

        if (playlist.isEmpty) {
          return const Center(child: Text('暂无歌曲'));
        }
        return ListView.builder(
          itemCount: playlist.length,
          itemBuilder: (context, index) {
            final song = playlist[index];
            return SongRowTile(
              song: song,
              selected: index == currentIndex,
              onPlay: () => controller.selectIndex(index),
              onToggleFavorite: () => controller.toggleFavorite(song.id),
              isLiked: () => controller.isLiked(song.id),
              extraTrailing: () => RemoveIconButton(song: song, index: index),
            );
          },
        );
      }),
    );
  }
}

/// 队列内"移除"按钮 —— 不在 SongRowTile 默认 trailing 里(那是 ❤️+▶),
/// 这里队列内移除用单独的 ✕ 图标,语义跟详情页不一样。
class RemoveIconButton extends StatelessWidget {
  const RemoveIconButton({super.key, required this.song, required this.index});
  final Song? song;
  final int index;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.remove_circle_outline),
      onPressed: () {
        final controller = Get.find<PlayListController>(
          tag: DefaultValues.playlistControllerTag,
        );
        controller.removeSong(index);
      },
      tooltip: '移除',
    );
  }
}
