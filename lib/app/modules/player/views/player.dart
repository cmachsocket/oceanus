import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'lyrics_page.dart';
import '../../../widgets/song_cover.dart';
import '../controllers/player_controller.dart';
import '../../../core/constants/default_values.dart';
import '../../playlist/views/play_list_page.dart';
import '../../playlist/controllers/play_list_controller.dart';
import '../../../widgets/linked_detail_text.dart';
import '../widgets/music_progress_bar.dart';
import '../controllers/lyrics_controller.dart';
import '../../../data/models/snapshot.dart' show PlayOrder;

class Player extends StatelessWidget {
  Player({super.key});
  final controller = Get.find<PlayerController>(
    tag: DefaultValues.playerControllerTag,
  );
  final playlist = Get.find<PlayListController>(
    tag: DefaultValues.playlistControllerTag,
  );
  final lyricController = Get.find<LyricsController>();
  static const tileMaxLine = 1;
  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Get.back(),
        ),
        centerTitle: true,
        title: Obx(() {
          final song = controller.currentSong.value;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                song?.title ?? '未在播放',
                style: textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
                maxLines: tileMaxLine,
                overflow: TextOverflow.ellipsis,
              ),
              if (song != null)
                LinkedDetailText(
                  song: song,
                  mainAxisAlignment: MainAxisAlignment.center,
                  textStyle: textTheme.bodyMedium,
                  backFirst: true,
                ),
            ],
          );
        }),
      ),
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Obx(() {
            return controller.center.value == CenterPage.lyric
                ? FloatingActionButton(
                    heroTag: 'lyricModeSwitch',
                    onPressed: lyricController.switchLyric,
                    child:
                        // exhaustive switch: enum 加新 page 时编译器报错,不会走错 icon
                        switch (lyricController.lyricShowMode.value) {
                          LyricShowMode.original => const Icon(Icons.block),
                          LyricShowMode.translation => const Icon(
                            Icons.translate,
                          ),
                          LyricShowMode.romaji => const Icon(
                            Icons.sort_by_alpha,
                          ),
                        },
                  )
                : const SizedBox.shrink();
          }),
          FloatingActionButton(
            heroTag: 'centerPageSwitch',
            onPressed: controller.switchPage,
            child: Obx(() {
              // exhaustive switch: enum 加新 page 时编译器报错,不会走错 icon
              final icon = switch (controller.center.value) {
                CenterPage.cover => Icons.music_note,
                CenterPage.lyric => Icons.lyrics,
              };
              return Icon(icon);
            }),
          ),
        ],
      ),
      body: Column(
        children: [
          // 图片 / 歌词:Expanded 占满中间区域
          Expanded(
            child: Obx(
              () => GestureDetector(
                onSecondaryTap: controller.switchPage,
                child: Center(
                  // 不再用 IndexedStack 同时保留封面/歌词两层：隐藏的歌词层
                  // (LyricView，内部有滚动/触摸 seek) 会在切歌后留下手势与滚动状态，
                  // 造成触控竞争、点不准。这里按当前页条件渲染，只挂载一层。
                  child: controller.center.value == CenterPage.cover
                      ? AspectRatio(
                          aspectRatio: DefaultValues.squardRatio,
                          child: Obx(() {
                            final song = controller.currentSong.value;
                            return SongCover(url: song?.coverUrl ?? '');
                          }),
                        )
                      : const Lyrics(),
                ),
              ),
            ),
          ),
        ],
      ),

      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MusicProgressBar(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: const Icon(Icons.skip_previous),
                onPressed: _gotoPrev,
              ),
              Obx(
                () => IconButton(
                  icon: Icon(
                    controller.isPlaying.value ? Icons.pause : Icons.play_arrow,
                  ),
                  onPressed: controller.togglePlay,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.skip_next),
                onPressed: _gotoNext,
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Obx(() {
                // 三模式循环: sequential → shuffle → repeatOne → sequential
                final m = playlist.mode.value;
                return IconButton(
                  icon: Icon(_modeIcon(m)),
                  tooltip: _modeTooltip(m),
                  onPressed: () => playlist.setMode(_nextMode(m)),
                );
              }),
              Obx(() {
                final song = controller.currentSong.value;
                return IconButton(
                  icon: Icon(
                    controller.isLiked.value
                        ? Icons.favorite
                        : Icons.favorite_border,
                    color: controller.isLiked.value
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  onPressed: song == null ? null : controller.toggleFavorite,
                  tooltip: controller.isLiked.value ? '取消喜欢' : '喜欢',
                );
              }),
              IconButton(
                icon: const Icon(Icons.playlist_play),
                onPressed: () => Get.to(() => const PlayListPage()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _gotoNext() {
    // wrapper.skipToNext 内部 _neighbor(1) 按 mode 计算索引:
    //   - sequential: +1 wrap
    //   - shuffle:    走 _shuffleOrder 序列
    //   - repeatOne:  返回 _currentIndex → handler _playAt 重置+play(同首从头)
    // 一行覆盖三模式,不再需要上层判断 + 手动 seek(0) + play()
    controller.next();
  }

  void _gotoPrev() {
    controller.prev();
  }

  /// 顺/乱/单 三模式循环 (sequential → shuffle → repeatOne → sequential)
  static PlayOrder _nextMode(PlayOrder m) {
    switch (m) {
      case PlayOrder.sequential:
        return PlayOrder.shuffle;
      case PlayOrder.shuffle:
        return PlayOrder.repeatOne;
      case PlayOrder.repeatOne:
        return PlayOrder.sequential;
    }
  }

  static IconData _modeIcon(PlayOrder m) {
    switch (m) {
      case PlayOrder.sequential:
        return Icons.repeat;
      case PlayOrder.shuffle:
        return Icons.shuffle;
      case PlayOrder.repeatOne:
        return Icons.repeat_one;
    }
  }

  static String _modeTooltip(PlayOrder m) {
    switch (m) {
      case PlayOrder.sequential:
        return '顺序播放';
      case PlayOrder.shuffle:
        return '随机播放';
      case PlayOrder.repeatOne:
        return '单曲循环';
    }
  }
}
