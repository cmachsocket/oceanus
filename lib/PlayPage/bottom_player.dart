import 'music_progressbar.dart';
import '../widgets/song_cover.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'player.dart';
import 'player_controller.dart';
import '../PlayListPage/play_list_page.dart';
import 'package:responsive_builder/responsive_builder.dart';
import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import '../models/default.dart';

/// 底部 mini 播放器
///
/// - 数据来源:[PlayerController.currentSong](音视频状态)
/// - 进度条由 [PlayerController.position]/[duration] 驱动(just_audio stream 推)
/// - 点击跳转到全屏 [Player] 页
/// - 队列图标跳 [PlayListPage]
class BottomPlayer extends StatelessWidget {
  const BottomPlayer({super.key});
  static const tileMaxLine = 1;
  static const progressFlex = 1;
  static const toolBarFlex = 3;
  @override
  Widget build(BuildContext context) {
    final player = Get.find<PlayerController>(
      tag: DefaultValues.playerControllerTag,
    );
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: () => Get.to(() => Player(), binding: PlayerBinding()),
      child: Container(
        color: scheme.surfaceContainerHighest,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              flex: toolBarFlex,
              child: Row(
                children: [
                  // 封面(从当前歌曲拿;无歌曲时退化占位)
                  // 用 AspectRatio 1:1 + BoxFit.cover,让 Row 自身高度约束决定封面大小,
                  // 不写死 48x48 —— 跟随主题 / 父容器高度走
                  Obx(() {
                    final song = player.currentSong.value;
                    return AspectRatio(
                      aspectRatio: DefaultValues.squardRatio,
                      child: SongCover(url: song?.coverUrl ?? ''),
                    );
                  }),
                  // 标题 + 艺术家
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Obx(
                          () => Text(
                            player.currentSong.value?.title ?? '未在播放',
                            style: textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: tileMaxLine,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Obx(() {
                          final song = player.currentSong.value;
                          return Text(
                            song?.artist ?? '-',
                            style: textTheme.bodySmall,
                            maxLines: tileMaxLine,
                            overflow: TextOverflow.ellipsis,
                          );
                        }),
                      ],
                    ),
                  ),
                  Obx(() {
                    final song = player.currentSong.value;
                    return IconButton(
                      icon: Icon(
                        player.isLiked.value
                            ? Icons.favorite
                            : Icons.favorite_border,
                        color: player.isLiked.value ? scheme.primary : null,
                      ),
                      onPressed: song == null ? null : player.toggleFavorite,
                      tooltip: player.isLiked.value ? '取消喜欢' : '喜欢',
                    );
                  }),
                  OrientationLayoutBuilder(
                    landscape: (_) => IconButton(
                      icon: const Icon(Icons.skip_previous),
                      onPressed: player.prev,
                    ),
                    portrait: (_) => SizedBox.shrink(),
                  ),
                  IconButton(
                    icon: Obx(
                      () => Icon(
                        player.isPlaying.value ? Icons.pause : Icons.play_arrow,
                      ),
                    ),
                    onPressed: player.togglePlay,
                  ),

                  IconButton(
                    icon: const Icon(Icons.skip_next),
                    onPressed: player.next,
                  ),
                  OrientationLayoutBuilder(
                    landscape: (_) => IconButton(
                      icon: const Icon(Icons.playlist_play),
                      onPressed: () => Get.to(
                        () => PlayListPage(),
                        binding: PlayListBinding(),
                      ),
                    ),
                    portrait: (_) => SizedBox.shrink(),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: progressFlex,
              child: MusicProgressBar(
                timeLabelLocation: TimeLabelLocation.sides,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
