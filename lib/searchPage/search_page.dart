import 'package:aspect_driven_grid/aspect_driven_grid.dart';
import 'package:flutter/material.dart' hide SearchController;
import 'package:get/get.dart';

import '../models/default.dart';
import '../ArtistPage/artist_detail.dart';
import '../SongListPage/songlist_body.dart';
import '../SongListPage/songlist_body_controller.dart';
import '../SongListPage/songlist_card.dart';
import '../SongListPage/songlist_detail.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../services/repositories/search_repository.dart'
    show SearchType, SearchPlaylistSummary;
import 'search_controller.dart';
import '../models/library_summary.dart' show PlaylistSource;

/// 搜索页(主 tab 之一)
///
/// - 顶部 [TextField] 输入关键词,提交触发 [SearchController.search]
/// - [SegmentedButton] 切 [SearchType]:同 keyword 自动重搜
/// - 4 个 view 各自走对应的容器:
///   - 单曲 → [SongListBody](空态 / loading / 错误三态)
///   - 专辑 / 艺人 / 歌单 → [AspectDrivenGrid] + [SongListCard]
class SearchPage extends StatelessWidget {
  const SearchPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<SearchController>();
    return Column(
      children: [
        const _SearchBar(),
        Obx(
          () => SegmentedButton<SearchType>(
            segments: [
              for (final t in SearchType.values)
                ButtonSegment(value: t, label: Text(t.label)),
            ],
            selected: {controller.type.value},
            onSelectionChanged: (s) => controller.setType(s.first),
            showSelectedIcon: false,
          ),
        ),
        Expanded(child: Obx(() => _SearchResults(type: controller.type.value))),
      ],
    );
  }
}

class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.type});

  final SearchType type;

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<SearchController>();
    return switch (type) {
      SearchType.song => _SongView(c: controller),
      SearchType.album => _AlbumGridView(c: controller),
      SearchType.artist => _ArtistGridView(c: controller),
      SearchType.playlist => _PlaylistGridView(c: controller),
    };
  }
}

/// 单曲列表:复用 SongListBody(已有 loading / empty / list 三态)
///
/// **数据源**:不再调后端。通过 [SongListBodyController] 的 `loadSongsCustom` 钩子,
/// 直接把 `SearchController.songResults` 喂给 body;`Obx` 监听变化时手动
/// `body.songs.assignAll(...)`,body 内部的 Obx 检测到 Rx 变化触发重建。
///
/// **生命周期**(纯 StatelessWidget,不用 StatefulWidget —— 这是项目硬要求):
/// `!isRegistered` 守卫保证同一 tag 只 put 一次;keyword 切换时旧 tag 的
/// controller 在路由 pop(`permanent: false`)时被 GetX 自动清理。
class _SongView extends StatelessWidget {
  const _SongView({required this.c});

  final SearchController c;

  /// 每条搜索结果对应一个 body controller tag(用 keyword 区分,
  /// 不同关键词产生不同 controller 实例 —— 防止切关键词时旧数据残留)。
  String _tagFor(String keyword) => 'search-$keyword-${PlaylistSource.pure}';

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final keyword = c.submittedKeyword.value;
      // loading + 错误 + 空 三态分流
      if (c.isLoading.value && c.songResults.isEmpty) {
        return const Center(child: CircularProgressIndicator());
      }
      if (c.errorMessage.value != null && c.songResults.isEmpty) {
        return _ErrorView(text: c.errorMessage.value!);
      }
      if (c.songResults.isEmpty && keyword.isEmpty) {
        return const _HintView(text: '输入关键词开始搜索');
      }
      if (c.songResults.isEmpty) {
        return _HintView(text: '没有匹配 "$keyword" 的单曲');
      }

      final tag = _tagFor(keyword);

      // **架构决定**:build() 永远不修改 Rx。这里只"选 controller",
      // 实际同步交给 [loadSongsCustom] + [SongListBodyController.watchExternal]
      // (在 onInit 链外执行,不阻塞 widget build)。
      //
      // **生命周期**:第一次 build → Get.put → onInit → microtask 调 _loadSongs
      // → loadSongsCustom 赋值 body.songs + 注册 ever worker;之后同 tag 已注册
      // → 跳过 Get.put;外部 songResults 变化 → ever worker → body.songs 同步
      // → SongListBody 内部 Obx rebuild;切 keyword → 旧 tag controller 被 GetX
      // 回收(permanent: false)→ onClose 释放 ever worker。
      if (!Get.isRegistered<SongListBodyController>(tag: tag)) {
        Get.put(
          SongListBodyController(
            playlistId: keyword, // 用 keyword 当 playlistId(占位)
            source: PlaylistSource.pure,
            loadSongsCustom: (body) {
              // sync 钩子,在 Future.microtask 内调用(已避开 build 同步链):
              // 1. 立即给 body.songs 赋当前搜索结果
              body.songs.assignAll(c.songResults.toList(growable: false));
              // 2. 注册 ever worker,后续 c.songResults 变化自动同步到 body.songs
              body.watchExternal(c.songResults, body.songs);
            },
          ),
          tag: tag,
          permanent: false,
        );
      }

      return SongListBody(controllerTag: tag);
    });
  }
}

class _AlbumGridView extends StatelessWidget {
  const _AlbumGridView({required this.c});

  final SearchController c;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (c.isLoading.value && c.albumResults.isEmpty) {
        return const Center(child: CircularProgressIndicator());
      }
      if (c.albumResults.isEmpty && c.submittedKeyword.value.isEmpty) {
        return const _HintView(text: '输入关键词开始搜索');
      }
      if (c.albumResults.isEmpty) {
        return _HintView(text: '没有匹配 "${c.submittedKeyword.value}" 的专辑');
      }
      return _grid<Album>(
        items: c.albumResults.toList(),
        toCard: (a) => SongListCard(
          playlistId: a.id,
          source: PlaylistSource.album,
          title: a.name,
          subtitle: '${a.songCount}首',
          imageUrl: a.coverUrl,
          isLiked: () => c.isAlbumLiked(a.id),
          onToggleFavorite: () => c.toggleAlbumLike(a.id),
          onTap: () => Get.to(
            () => SongListDetail(
              displayTitle: a.name,
              controllerTag: a.id + PlaylistSource.album.toString(),
            ),
            id: DefaultValues.shellNavigatorId,
            binding: SongListDetailBinding(
              playlistId: 'album-${a.id}',
              source: PlaylistSource.album,
            ),
          ),
        ),
      );
    });
  }
}

class _ArtistGridView extends StatelessWidget {
  const _ArtistGridView({required this.c});

  final SearchController c;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (c.isLoading.value && c.artistResults.isEmpty) {
        return const Center(child: CircularProgressIndicator());
      }
      if (c.artistResults.isEmpty && c.submittedKeyword.value.isEmpty) {
        return const _HintView(text: '输入关键词开始搜索');
      }
      if (c.artistResults.isEmpty) {
        return _HintView(text: '没有匹配 "${c.submittedKeyword.value}" 的艺人');
      }
      return _grid<Artist>(
        items: c.artistResults.toList(),
        toCard: (a) => SongListCard(
          playlistId: a.id,
          source: PlaylistSource.artist,
          title: a.name,
          subtitle: '${a.albumCount}张专辑 · ${a.songCount}首歌',
          imageUrl: a.photoUrl,
          isLiked: () => c.isArtistLiked(a.id),
          onToggleFavorite: () => c.toggleArtistLike(a.id),
          onTap: () => Get.to(
            () => ArtistDetail(artistId: a.id),
            id: DefaultValues.shellNavigatorId,
            binding: ArtistDetailBinding(artistId: a.id),
          ),
        ),
      );
    });
  }
}

class _PlaylistGridView extends StatelessWidget {
  const _PlaylistGridView({required this.c});

  final SearchController c;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (c.isLoading.value && c.playlistResults.isEmpty) {
        return const Center(child: CircularProgressIndicator());
      }
      if (c.playlistResults.isEmpty && c.submittedKeyword.value.isEmpty) {
        return const _HintView(text: '输入关键词开始搜索');
      }
      if (c.playlistResults.isEmpty) {
        return _HintView(text: '没有匹配 "${c.submittedKeyword.value}" 的歌单');
      }
      return _grid<SearchPlaylistSummary>(
        items: c.playlistResults.toList(),
        toCard: (p) => SongListCard(
          playlistId: p.id,
          source: PlaylistSource.collected,
          title: p.name,
          subtitle: '${p.trackCount}首',
          imageUrl: p.coverUrl,
          isLiked: () => c.isPlaylistLiked(p.id),
          onToggleFavorite: () => c.togglePlaylistLike(p.id),
          onTap: () => Get.to(
            () => SongListDetail(
              displayTitle: p.name,
              controllerTag: p.id + PlaylistSource.collected.toString(),
            ),
            id: DefaultValues.shellNavigatorId,
            binding: SongListDetailBinding(
              playlistId: p.id,
              source: PlaylistSource.collected,
            ),
          ),
        ),
      );
    });
  }
}

/// 通用 grid 容器(避免 AspectDrivenGrid 包法重复)
Widget _grid<T>({
  required List<T> items,
  required Widget Function(T item) toCard,
}) {
  return OrientationBuilder(
    builder: (context, orientation) {
      final aspectRatio = orientation == Orientation.portrait
          ? DefaultValues.portraitGridChildAspectRatio
          : DefaultValues.landscopeGridChildAspectRatio;
      return AspectDrivenGrid(
        minColumns: 2,
        childAspectRatio: aspectRatio,
        itemCount: items.length,
        itemBuilder: (context, index) => toCard(items[index]),
      );
    },
  );
}

/// 错误占位
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(child: Text('加载失败:$text', textAlign: TextAlign.center));
  }
}

/// 提示占位(空状态 / 未输入)
class _HintView extends StatelessWidget {
  const _HintView({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(child: Text(text, textAlign: TextAlign.center));
  }
}

/// 搜索栏:TextField + 搜索图标 + 清除按钮
///
/// - 显式绑 [SearchController.textController] 给 [TextField.controller],
///   清除按钮才能真正清空输入框(不显式绑时 TextField 内部 state 复用看不见的 controller,
///   点清除只改了 RxString,输入框不响应)
/// - 提交触发 search;切 tab 由 controller.setType 内部自动重搜
class _SearchBar extends StatelessWidget {
  const _SearchBar();

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<SearchController>();
    return Obx(
      () => TextField(
        controller: controller.textController,
        textInputAction: TextInputAction.search,
        onSubmitted: controller.search,
        onChanged: controller.setKeyword,
        decoration: InputDecoration(
          hintText: '搜索歌曲、艺人、专辑、歌单',
          prefixIcon: IconButton(
            onPressed: () => controller.search(controller.textController.text),
            icon: const Icon(Icons.search),
          ),
          suffixIcon: controller.keyword.value.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: controller.clearKeyword,
                  tooltip: '清除',
                ),
        ),
      ),
    );
  }
}
