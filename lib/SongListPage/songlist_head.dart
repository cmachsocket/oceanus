import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../models/default.dart';
import '../models/library_summary.dart' show PlaylistSource;
import '../widgets/netease_image.dart';
import 'songlist_body_controller.dart';
import 'songlist_head_controller.dart';

/// 详情页 head 行 widget —— 通过 [controllerTag] 找到对应 [SongListHeadControllerBase],
/// 再按 [source] 委托给三套视觉之一(各有自己的布局,选哪个在本 widget 这层做完):
/// - `SongListHeadController` (歌单: created / collected / pure) → [_PlaylistHead]
/// - `AlbumHeadController`    (专辑)                              → [AlbumHead]
/// - `ArtistHeadController`   (艺人)                              → [ArtistHead]
///
/// head / body 两个 controller 由 `SongListDetail` 在 binding 时用同一个
/// `controllerTag = playlistId + source` 一起注册。
class SongListHead extends StatelessWidget {
  const SongListHead({super.key, required this.controllerTag});

  final String controllerTag;

  /// AppBar 上"返回"按钮的回退栈 id(沿用项目约定)
  static const int backNavigatorId = DefaultValues.shellNavigatorId;

  static const int rowMainTextMaxLines = 4;
  static const int rowSubTextMaxLines = 1;

  @override
  Widget build(BuildContext context) {
    final head = Get.find<SongListHeadControllerBase>(tag: controllerTag);
    final source = head.source;
    return switch (source) {
      PlaylistSource.album => AlbumHead(
        controller: head,
        controllerTag: controllerTag,
      ),
      PlaylistSource.artist => ArtistHead(
        controller: head,
        controllerTag: controllerTag,
      ),
      _ => _PlaylistHead(controller: head, controllerTag: controllerTag),
    };
  }
}

/// 歌单形态 head —— 描述 + 按钮列(播放 / 收藏 / 删除)。
///
/// 删除按钮仅 source == PlaylistSource.created 时显示 —— 收藏的 / 纯的不可删。
/// loading / 出错时整行隐藏(head 显示空字符串也没有意义)。
class _PlaylistHead extends StatelessWidget {
  const _PlaylistHead({required this.controller, required this.controllerTag});

  final SongListHeadControllerBase controller;
  final String controllerTag;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final body = Get.isRegistered<SongListBodyController>(tag: controllerTag)
        ? Get.find<SongListBodyController>(tag: controllerTag)
        : null;
    return Obx(() {
      if (controller.isLoading.value || controller.errorMessage.value != null) {
        return const SizedBox.shrink();
      }
      final songsEmpty = body?.songs.isEmpty ?? false;
      return Row(
        children: [
          Expanded(
            child: Obx(() {
              final description = controller.description.value?.trim() ?? '';
              return Text(
                description.isEmpty ? '暂无描述' : description,
                style: textTheme.bodyMedium,
                maxLines: SongListHead.rowMainTextMaxLines,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.left,
              );
            }),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.play_arrow),
                onPressed: songsEmpty ? null : controller.onPlayAll,
                label: Text(
                  '播放',
                  style: textTheme.bodyMedium,
                  maxLines: SongListHead.rowSubTextMaxLines,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Obx(() {
                // null (loading) → 不渲染
                if (controller.playlistSource.value == null) {
                  return const SizedBox.shrink();
                }
                // 自建(created) → 删除按钮(非 created 才显示收藏)
                if (controller.playlistSource.value == PlaylistSource.created) {
                  return TextButton.icon(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: controller.deletePlaylist,
                    label: Text(
                      '删除',
                      style: textTheme.bodyMedium,
                      maxLines: SongListHead.rowSubTextMaxLines,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }
                // 收藏的(collected)/ 搜索结果(pure) → 只显示收藏
                return _LikeButton(
                  liked: controller.isPlaylistFavorite,
                  onToggle: controller.toggleFavorite,
                );
              }),
            ],
          ),
        ],
      );
    });
  }
}

/// 收藏 ❤️ 按钮 widget —— 自建歌单 / 专辑 / 艺人 head 都会用到。
/// [liked] 内部读 Rx,包 Obx 自动响应收藏状态变化。
class _LikeButton extends StatelessWidget {
  const _LikeButton({required this.liked, required this.onToggle});

  final bool Function() liked;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return TextButton.icon(
      icon: Obx(
        () => Icon(
          liked() ? Icons.favorite : Icons.favorite_border,
          color: liked() ? Theme.of(context).colorScheme.primary : null,
        ),
      ),
      onPressed: onToggle,
      label: Text(
        '收藏',
        style: textTheme.bodyMedium,
        maxLines: SongListHead.rowSubTextMaxLines,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// 专辑形态 head —— 标题 + 描述 + 按钮列(播放 / 收藏)。**没有删除**(专辑不能删)。
///
/// 跟歌单形态相比:标题在标题列里(歌单 head 没有标题行,只显示描述)。
class AlbumHead extends StatelessWidget {
  const AlbumHead({
    super.key,
    required this.controller,
    required this.controllerTag,
  });

  final SongListHeadControllerBase controller;
  final String controllerTag;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final body = Get.isRegistered<SongListBodyController>(tag: controllerTag)
        ? Get.find<SongListBodyController>(tag: controllerTag)
        : null;
    return Obx(() {
      if (controller.isLoading.value || controller.errorMessage.value != null) {
        return const SizedBox.shrink();
      }
      final songsEmpty = body?.songs.isEmpty ?? false;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 标题(歌单形态没有这一行 —— 标题在 AppBar 里)
                Text(
                  controller.title.value ?? '',
                  style: textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  controller.description.value?.trim().isNotEmpty == true
                      ? controller.description.value!.trim()
                      : '暂无描述',
                  style: textTheme.bodyMedium,
                  maxLines: SongListHead.rowMainTextMaxLines,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.play_arrow),
                onPressed: songsEmpty ? null : controller.onPlayAll,
                label: Text(
                  '播放',
                  style: textTheme.bodyMedium,
                  maxLines: SongListHead.rowSubTextMaxLines,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _LikeButton(
                liked: controller.isPlaylistFavorite,
                onToggle: controller.toggleFavorite,
              ),
            ],
          ),
        ],
      );
    });
  }
}

/// 艺人形态 head —— 圆形头像 + 名字 + 简介 + 按钮列(播放全部 / 关注)。
/// **没有删除按钮**(艺人不能删)。
class ArtistHead extends StatelessWidget {
  const ArtistHead({
    super.key,
    required this.controller,
    required this.controllerTag,
  });

  final SongListHeadControllerBase controller;
  final String controllerTag;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final body = Get.isRegistered<SongListBodyController>(tag: controllerTag)
        ? Get.find<SongListBodyController>(tag: controllerTag)
        : null;
    return Obx(() {
      if (controller.isLoading.value || controller.errorMessage.value != null) {
        return const SizedBox.shrink();
      }
      final songsEmpty = body?.songs.isEmpty ?? false;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CircleAvatar(
            backgroundColor: scheme.surfaceContainerHigh,
            backgroundImage:
                controller.coverUrl.value == null ||
                    controller.coverUrl.value!.isEmpty
                ? null
                : neteaseNetworkImage(controller.coverUrl.value!),
            child:
                controller.coverUrl.value == null ||
                    controller.coverUrl.value!.isEmpty
                ? Icon(Icons.person, color: scheme.onSurfaceVariant)
                : null,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  controller.title.value ?? '',
                  style: textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  controller.description.value?.trim().isNotEmpty == true
                      ? controller.description.value!.trim()
                      : '暂无简介',
                  style: textTheme.bodyMedium,
                  maxLines: SongListHead.rowMainTextMaxLines,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.play_arrow),
                onPressed: songsEmpty ? null : controller.onPlayAll,
                label: Text(
                  '播放全部',
                  style: textTheme.bodyMedium,
                  maxLines: SongListHead.rowSubTextMaxLines,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // 关注(用 favorite icon 表示,语义统一)
              _LikeButton(
                liked: controller.isPlaylistFavorite,
                onToggle: controller.toggleFavorite,
              ),
            ],
          ),
        ],
      );
    });
  }
}
