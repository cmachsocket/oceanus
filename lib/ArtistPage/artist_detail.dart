import 'package:aspect_driven_grid/aspect_driven_grid.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../models/album.dart';
import '../models/default.dart';
import '../models/library_summary.dart' show PlaylistSource;
import '../SongListPage/songlist_body.dart';
import '../SongListPage/songlist_card.dart';
import '../SongListPage/songlist_detail.dart';
import '../SongListPage/songlist_head.dart';
import '../SongListPage/songlist_head_controller.dart';
import 'artist_controller.dart';

/// 艺人详情页 —— **复用 head + body 体系**(`ArtistHeadController` /
/// `SongListBodyController`),中间插 [SegmentedButton] 切 EP/专辑 网格 vs 所有歌曲列表。
///
/// **结构**:
/// ```
/// AppBar (动态标题 from head)
/// ─── SongListHead(controllerTag)              ← 复用 head
/// ─── SegmentedButton(view)                     ← view state 在 ArtistController
/// ─── switch content:
///     ├─ view == albums → _AlbumsSection        ← AspectDrivenGrid + SongListCard
///     └─ view == songs  → SongListBody          ← 复用 body
/// ```
///
/// **controller 三方**:
/// - [ArtistHeadController] (head):艺人元信息 + 关注 + 播放全部
/// - [SongListBodyController] (body):所有歌曲列表(`/artist/songs`)
/// - [ArtistController] (本文件):view state + 专辑列表(`/artist/albums`) + 专辑收藏
///
/// 三方共用同一 `controllerTag = artistId + artist`,binding 时一起注入。
/// head 不直接依赖 [ArtistController],body 也不依赖 —— 它们读各自的 Rx。
class ArtistDetail extends StatelessWidget {
  const ArtistDetail({super.key, required this.artistId});

  final String artistId;

  /// 跟 head / body / ArtistController 共享的 controller tag
  String get _controllerTag => '$artistId${PlaylistSource.artist}';

  @override
  Widget build(BuildContext context) {
    final head = Get.find<SongListHeadControllerBase>(tag: _controllerTag);
    final artistCtrl = Get.find<ArtistController>(tag: _controllerTag);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Get.back(id: DefaultValues.shellNavigatorId),
          icon: const Icon(Icons.arrow_back),
        ),
        title: Obx(() => Text('艺人 · ${head.title.value ?? artistId}')),
      ),
      body: Column(
        children: [
          // 复用 head (圆形头像 + 名字 + bio + 播放全部 + 关注)
          SongListHead(controllerTag: _controllerTag),

          // EP/专辑 ↔ 所有歌曲 切换
          _ViewSwitcher(controller: artistCtrl),

          // 主内容:Album 网格 或 歌曲列表
          Expanded(
            child: Obx(() {
              switch (artistCtrl.view.value) {
                case ArtistView.albums:
                  return _AlbumsSection(controller: artistCtrl);
                case ArtistView.songs:
                  return SongListBody(controllerTag: _controllerTag);
              }
            }),
          ),
        ],
      ),
    );
  }
}

// ---- 视图切换 ---------------------------------------------------------------

class _ViewSwitcher extends StatelessWidget {
  const _ViewSwitcher({required this.controller});

  final ArtistController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => SegmentedButton<ArtistView>(
        segments: const [
          ButtonSegment(
            value: ArtistView.albums,
            label: Text('专辑 / EP'),
            icon: Icon(Icons.album),
          ),
          ButtonSegment(
            value: ArtistView.songs,
            label: Text('所有歌曲'),
            icon: Icon(Icons.queue_music),
          ),
        ],
        selected: {controller.view.value},
        onSelectionChanged: (s) => controller.setView(s.first),
      ),
    );
  }
}

// ---- EP/专辑 网格 ----------------------------------------------------------

class _AlbumsSection extends StatelessWidget {
  const _AlbumsSection({required this.controller});

  final ArtistController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // loading
      if (controller.isAlbumsLoading.value && controller.albums.isEmpty) {
        return const Center(child: CircularProgressIndicator());
      }
      // 错误
      if (controller.albumsError.value != null && controller.albums.isEmpty) {
        final scheme = Theme.of(context).colorScheme;
        return Center(
          child: Text(
            '加载失败: ${controller.albumsError.value}',
            style: TextStyle(color: scheme.error),
          ),
        );
      }
      // 空
      if (controller.albums.isEmpty) {
        return const Center(child: Text('暂无专辑'));
      }
      // 网格
      final List<Album> albums = controller.albums.toList(growable: false);
      return OrientationBuilder(
        builder: (context, orientation) {
          final aspectRatio = orientation == Orientation.portrait
              ? DefaultValues.portraitGridChildAspectRatio
              : DefaultValues.landscopeGridChildAspectRatio;
          return AspectDrivenGrid(
            itemCount: albums.length,
            childAspectRatio: aspectRatio,
            minColumns: DefaultValues.gridMinColumns,
            itemBuilder: (context, index) {
              final album = albums[index];
              return SongListCard(
                playlistId: album.id,
                source: PlaylistSource.album,
                title: album.name,
                subtitle: '${album.type.label} · ${album.songCount}首',
                imageUrl: album.coverUrl,
                isLiked: () => controller.isAlbumLiked(album.id),
                onToggleFavorite: () =>
                    controller.toggleAlbumFavorite(album.id),
              );
            },
          );
        },
      );
    });
  }
}

// ---- Binding ----------------------------------------------------------------

/// ArtistDetail 的 binding —— 同时注入 head + body + ArtistController。
///
/// **三个 controller 共用 `controllerTag = artistId + source`**,widget
/// 通过同一个 tag 找所有 controller。
class ArtistDetailBinding extends Bindings {
  ArtistDetailBinding({required this.artistId});

  final String artistId;

  @override
  void dependencies() {
    final tag = '$artistId${PlaylistSource.artist}';

    // head + body:复用 SongListDetailBinding 的逻辑
    SongListDetailBinding(
      playlistId: artistId,
      source: PlaylistSource.artist,
    ).dependencies();

    // ArtistController:view 切换 + 专辑列表
    Get.lazyPut<ArtistController>(
      () => ArtistController(artistId: artistId),
      tag: tag,
    );
  }
}
