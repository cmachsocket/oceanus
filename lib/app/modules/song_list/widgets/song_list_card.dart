import 'package:flutter/material.dart';
import '../../../widgets/song_cover.dart';
import 'package:get/get.dart';
import 'package:responsive_builder/responsive_builder.dart';
import '../../../core/constants/default_values.dart';
import '../../../data/models/library_summary.dart' show PlaylistSource;
import '../../../services/playlist_events_controller.dart';
import '../controllers/song_list_body_controller.dart';
import '../bindings/song_list_detail_binding.dart';
import '../views/song_list_detail.dart';

/// 整张歌单播放回调(返回 Future 但卡片场景 fire-and-forget)
typedef PlayPlaylistCallback = Future<void> Function();

/// 查询目标资源是否被喜欢/收藏/关注
typedef IsLikedGetter = bool Function();

/// 主页歌单卡片
///
/// - [playlistId] 由调用方注入(主页 HomePage 把每天推荐/私人FM/推荐歌单的 ID 传进来)
/// - 默认点击走 [Get.to] 推到 `AppShell` 的嵌套 Navigator 上(保留底部 [BottomPlayer]);
///   进入后自动按 ID 拉数据([SongListBodyController] / [SongListHeadController]
///   由 binding 注入,路由 pop 时自动销毁)
/// - [onTap] 传了就用自定义导航(艺人/专辑卡片可以借此推到自己的详情页);
///   传 null 就走默认 SongListDetail 导航
class SongListCard extends StatelessWidget {
  const SongListCard({
    super.key,
    required this.playlistId,
    required this.source,
    this.title,
    this.subtitle,
    this.trackCount,
    this.imageUrl,
    this.onTap,
    this.onPlay,
    this.isLiked,
    this.onToggleFavorite,
    this.showLike = true,
  });

  final String playlistId;

  /// 歌单来源(自建 / 收藏 / 专辑 / 艺人 / 搜索结果 / 等等),
  /// 传给 [SongListDetailBinding] 决定 body / head 的 fetch 路径。
  final PlaylistSource source;
  final String? title;

  /// 默认副标题字符串。如果 [trackCount] 也传了,优先用 trackCount + delta 显示
  /// 实时数量(响应式)。否则 fallback 到这个静态字符串(专辑 / 艺人等
  /// 没有 trackCount 概念的 card 用)。
  final String? subtitle;

  /// 实时曲目数(从 LibraryController.playlists 拿到的 base 值)。
  /// 传了之后,widget 会 Obx 监听 [PlaylistEventsController.deltaFor] 累加 delta,
  /// 显示 `trackCount + delta`。专辑 / 艺人不传,只传 playlist 卡片。
  final int? trackCount;
  final String? imageUrl;

  /// 覆盖默认导航。null = 默认跳 SongListDetail
  final VoidCallback? onTap;

  /// 覆盖默认播放(整张歌单)。null = 默认调 SongListBodyController.playPlaylistById
  final PlayPlaylistCallback? onPlay;

  /// 查询当前 [playlistId] 是否被喜欢/收藏/关注
  ///
  /// - **必须在 Obx 内调用**才能响应 likedXxxIds 变化
  /// - widget 不直接 Get.find service,调用方注入响应式查询
  final IsLikedGetter? isLiked;

  /// 点击 ♥ 触发的操作
  ///
  /// - 调用方决定调哪个 service 的 toggle
  /// - widget 内 fire-and-forget,不 await
  final VoidCallback? onToggleFavorite;

  /// 是否渲染红心按钮。默认 true。
  ///
  /// - false: 横屏 trailing 只剩播放按钮
  /// - 用于自建歌单等"语义上不属于收藏"的场景（自建歌单没法"再收藏一次"）
  final bool showLike;

  static const cardTextMaxLines = 2;
  static const subTextMaxLines = 1;
  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: GestureDetector(
        onTap: onTap ?? _defaultNavigate,
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: DefaultValues.squardRatio,
              child: SongCover(url: imageUrl ?? ''),
            ),

            ListTile(
              title: Text(
                title ?? '',
                style: textTheme.bodySmall,
                maxLines: cardTextMaxLines,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: trackCount != null
                  // 响应式:base count + delta(addTracks/removeTracks 累积)
                  ? Obx(() {
                      final delta = Get.find<PlaylistEventsController>()
                          .deltaFor(playlistId);
                      final total = trackCount! + delta;
                      return Text(
                        '$total 首',
                        style: textTheme.bodySmall,
                        maxLines: subTextMaxLines,
                        overflow: TextOverflow.ellipsis,
                      );
                    })
                  : Text(
                      subtitle ?? '',
                      style: textTheme.bodySmall,
                      maxLines: subTextMaxLines,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: OrientationLayoutBuilder(
                landscape: (_) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showLike)
                      _LikeButton(
                        isLiked: isLiked,
                        onToggleFavorite: onToggleFavorite,
                        playlistId: playlistId,
                      ),
                    IconButton(
                      icon: Icon(Icons.play_circle_fill_outlined),
                      onPressed: () {
                        final cb =
                            onPlay ??
                            () => SongListBodyController.playPlaylistById(
                              playlistId,
                            );
                        cb(); // fire-and-forget
                      },
                    ),
                  ],
                ),
                portrait: (_) => SizedBox.shrink(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _defaultNavigate() {
    Get.to(
      () => SongListDetail(
        displayTitle: title,
        controllerTag: playlistId + source.toString(),
      ),
      id: DefaultValues.shellNavigatorId,
      binding: SongListDetailBinding(playlistId: playlistId, source: source),
    );
  }
}

class LineSongListCard extends StatelessWidget {
  const LineSongListCard({
    super.key,
    required this.playlistId,
    required this.source,
    this.title,
    this.subtitle,
    this.imageUrl,
    this.onPlay,
  });

  final String playlistId;
  final PlaylistSource source;
  final String? title;
  final String? subtitle;
  final String? imageUrl;

  static const bodyTextMaxLines = 1;

  /// 覆盖默认播放(整张歌单)。null = 默认调 SongListBodyController.playPlaylistById
  final PlayPlaylistCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: () => Get.to(
          () => SongListDetail(
            displayTitle: title,
            controllerTag: playlistId + source.toString(),
          ),
          id: DefaultValues.shellNavigatorId,
          binding: SongListDetailBinding(
            playlistId: playlistId,
            source: source,
          ),
        ),
        leading: SongCover(url: imageUrl ?? ''),
        title: Text(
          title ?? '',
          style: textTheme.bodySmall,
          maxLines: bodyTextMaxLines,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          subtitle ?? '',
          style: textTheme.bodySmall,
          maxLines: bodyTextMaxLines,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          icon: Icon(Icons.play_circle_fill_outlined),
          onPressed: () {
            final cb =
                onPlay ??
                () => SongListBodyController.playPlaylistById(playlistId);
            cb(); // fire-and-forget
          },
        ),
      ),
    );
  }
}

/// 歌单/专辑/艺人卡片的 ♥ 按钮
///
/// - **widget 不接触 service**:所有状态查询 / 操作都走 [SongListCard] 注入的 callback
/// - widget 内部 Obx 包 [isLiked] 调用 → 响应 likedXxxIds 变化
/// - 首次 build 时调 [onFirstBuild](典型场景:艺人卡片主动同步关注状态)
class _LikeButton extends StatelessWidget {
  const _LikeButton({
    required this.playlistId,
    required this.isLiked,
    required this.onToggleFavorite,
  });

  final String playlistId;
  final IsLikedGetter? isLiked;
  final VoidCallback? onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 没 isLiked callback 时直接静态 IconButton ——不包 Obx
    // (包 Obx 但体内不读 Rx 会报 "improper use of GetX")
    if (isLiked == null) {
      return IconButton(
        icon: const Icon(Icons.favorite_border),
        onPressed: () {
          onToggleFavorite?.call();
        },
        tooltip: '收藏',
      );
    }
    return Obx(() {
      final liked = isLiked?.call() ?? false;
      return IconButton(
        icon: Icon(
          liked ? Icons.favorite : Icons.favorite_border,
          color: liked ? scheme.primary : null,
        ),
        onPressed: () {
          onToggleFavorite?.call();
        },
        tooltip: liked ? '取消收藏' : '收藏',
      );
    });
  }
}
