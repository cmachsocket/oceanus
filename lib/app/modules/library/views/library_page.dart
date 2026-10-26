import 'package:aspect_driven_grid/aspect_driven_grid.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../artist/bindings/artist_detail_binding.dart';
import '../../artist/views/artist_detail.dart';
import '../../song_list/widgets/song_list_card.dart';
import '../../../../sdk/auth_controller.dart';
import '../controllers/library_controller.dart';
import '../../../core/constants/default_values.dart';
import '../../../data/models/library_summary.dart' show PlaylistSource;

/// 我的 tab 内容
///
/// 三个 tab 都需登录。未登录展示"请先登录"占位,登录后按 tab 走对应 SDK 接口
class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<LibraryController>();
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: controller.addPlaylist,
        child: Icon(Icons.add),
      ),
      body: Obx(() {
        final tab = controller.tab.value;
        return Column(
          children: [
            SegmentedButton<LibraryTab>(
              segments: LibraryTab.values
                  .map(
                    (t) => ButtonSegment(
                      label: Text(t.label),
                      icon: Icon(t.icon),
                      value: t,
                    ),
                  )
                  .toList(),

              selected: {tab},
              onSelectionChanged: (s) => controller.setTab(s.first),
            ),
            Expanded(child: _TabContent(tab: tab)),
          ],
        );
      }),
    );
  }
}

/// 各 tab 的具体内容(包含未登录占位)
class _TabContent extends StatelessWidget {
  const _TabContent({required this.tab});

  final LibraryTab tab;

  @override
  Widget build(BuildContext context) {
    final auth = Get.find<AuthController>();
    return Obx(() {
      if (!auth.loggedIn) {
        return const _LoginRequiredHint();
      }
      // exhaustive switch: enum 加新值时编译器报错,不会静默走错分支
      switch (tab) {
        case LibraryTab.playlists:
          return _PlaylistsView();
        case LibraryTab.albums:
          return _AlbumsView();
        case LibraryTab.artists:
          return _ArtistsView();
      }
    });
  }
}

/// "请先登录"占位卡
class _LoginRequiredHint extends StatelessWidget {
  const _LoginRequiredHint();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.login),
        title: const Text('登录后查看我的歌单 / 专辑 / 艺人'),
        subtitle: const Text('点底部「我」tab 进入设置 → 登录账号'),
      ),
    );
  }
}

/// 歌单 grid
class _PlaylistsView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = Get.find<LibraryController>();
    return Obx(() {
      if (c.playlistsLoading.value) {
        return const Center(child: CircularProgressIndicator());
      }
      if (c.playlistsError.value != null) {
        return Center(
          child: Text(
            '加载失败:${c.playlistsError.value}',
            textAlign: TextAlign.center,
          ),
        );
      }
      if (c.playlists.isEmpty) {
        return const Center(child: Text('暂无歌单'));
      }
      return OrientationBuilder(
        builder: (context, orientation) {
          final aspectRatio = orientation == Orientation.portrait
              ? DefaultValues.portraitGridChildAspectRatio
              : DefaultValues.landscopeGridChildAspectRatio;
          return AspectDrivenGrid(
            childAspectRatio: aspectRatio,
            minColumns: DefaultValues.gridMinColumns,
            itemCount: c.playlists.length,
            itemBuilder: (context, index) {
              final p = c.playlists[index];
              // 自建歌单不显示红心按钮 —— 没有"再收藏一次"的语义
              // 只有 source == collected 的歌单才让 liked toggle 有意义
              final showLike = p.source == PlaylistSource.collected;
              return SongListCard(
                playlistId: p.id,
                source: p.source,
                title: p.name,
                // 不再传 subtitle = '${p.trackCount} 首' ——
                // 改成传 trackCount 让 SongListCard 自己 Obx 算 delta
                // 响应 addTracks / removeTracks。
                trackCount: p.trackCount,
                imageUrl: p.picUrl,
                showLike: showLike,
                isLiked: showLike ? () => c.isPlaylistLiked(p.id) : null,
                onToggleFavorite: showLike
                    ? () => c.togglePlaylistLike(p.id)
                    : null,
              );
            },
          );
        },
      );
    });
  }
}

/// 专辑 grid
class _AlbumsView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = Get.find<LibraryController>();
    return Obx(() {
      if (c.albumsLoading.value) {
        return const Center(child: CircularProgressIndicator());
      }
      if (c.albumsError.value != null) {
        return Center(
          child: Text(
            '加载失败:${c.albumsError.value}',
            textAlign: TextAlign.center,
          ),
        );
      }
      if (c.albums.isEmpty) {
        return const Center(child: Text('暂无订阅专辑'));
      }
      return OrientationBuilder(
        builder: (context, orientation) {
          final aspectRatio = orientation == Orientation.portrait
              ? DefaultValues.portraitGridChildAspectRatio
              : DefaultValues.landscopeGridChildAspectRatio;
          return AspectDrivenGrid(
            childAspectRatio: aspectRatio,
            minColumns: DefaultValues.gridMinColumns,
            itemCount: c.albums.length,
            itemBuilder: (context, index) {
              final a = c.albums[index];
              return SongListCard(
                playlistId: a.id,
                source: PlaylistSource.album,
                title: a.name,
                subtitle: a.artist,
                imageUrl: a.picUrl,
                isLiked: () => c.isAlbumLiked(a.id),
                onToggleFavorite: () => c.toggleAlbumLike(a.id),
              );
            },
          );
        },
      );
    });
  }
}

/// 艺人 grid(跳 ArtistDetail,不走 SongListDetail)
class _ArtistsView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = Get.find<LibraryController>();
    return Obx(() {
      if (c.artistsLoading.value) {
        return const Center(child: CircularProgressIndicator());
      }
      if (c.artistsError.value != null) {
        return Center(
          child: Text(
            '加载失败:${c.artistsError.value}',
            textAlign: TextAlign.center,
          ),
        );
      }
      if (c.artists.isEmpty) {
        return const Center(child: Text('暂无关注艺人'));
      }
      return OrientationBuilder(
        builder: (context, orientation) {
          final aspectRatio = orientation == Orientation.portrait
              ? DefaultValues.portraitGridChildAspectRatio
              : DefaultValues.landscopeGridChildAspectRatio;
          return AspectDrivenGrid(
            minColumns: DefaultValues.gridMinColumns,
            childAspectRatio: aspectRatio,
            itemCount: c.artists.length,
            itemBuilder: (context, index) {
              final a = c.artists[index];
              return SongListCard(
                playlistId: a.id,
                source: PlaylistSource.artist,
                title: a.name,
                subtitle: '',
                imageUrl: a.picUrl,
                isLiked: () => c.isArtistLiked(a.id),
                onToggleFavorite: () => c.toggleArtistLike(a.id),
                onTap: () => Get.to(
                  () => ArtistDetail(artistId: a.id),
                  id: DefaultValues.shellNavigatorId,
                  binding: ArtistDetailBinding(artistId: a.id),
                ),
              );
            },
          );
        },
      );
    });
  }
}
