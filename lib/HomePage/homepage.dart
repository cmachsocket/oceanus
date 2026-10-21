import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../SongListPage/songlist_card.dart';
import '../widgets/aspect_driven_grid.dart';
import 'home_controller.dart';
import '../models/default.dart';
import '../models/library_summary.dart' show PlaylistSource;

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final home = Get.find<HomeController>();
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('推荐歌单', style: textTheme.titleLarge),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: home.load,
          ),
        ],
      ),
      body:
          // 推荐歌单网格
          _RecommendedGrid(home: home),
    );
  }
}

/// 推荐歌单网格:loading / error / 数据三态
class _RecommendedGrid extends StatelessWidget {
  const _RecommendedGrid({required this.home});

  final HomeController home;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      if (home.isLoading.value) {
        return const Center(child: CircularProgressIndicator());
      }
      if (home.errorMessage.value != null) {
        return Center(
          child: Text(
            '加载失败:${home.errorMessage.value}',
            textAlign: TextAlign.center,
          ),
        );
      }
      if (home.recommended.isEmpty) {
        return const Center(child: Text('暂无推荐'));
      }
      return OrientationBuilder(
        builder: (context, orientation) {
          final aspectRatio = orientation == Orientation.portrait
              ? DefaultValues.portraitGridChildAspectRatio
              : DefaultValues.landscopeGridChildAspectRatio;
          return AspectDrivenGrid(
            childAspectRatio: aspectRatio,
            minColumns: DefaultValues.gridMinColumns,
            itemCount: home.recommended.length,
            itemBuilder: (context, index) {
              final card = home.recommended[index];
              return SongListCard(
                playlistId: card.id,
                source: PlaylistSource.collected,
                title: card.name,
                subtitle: '',
                imageUrl: card.picUrl,
                isLiked: () => home.isPlaylistLiked(card.id),
                onToggleFavorite: () => home.togglePlaylistLike(card.id),
              );
            },
          );
        },
      );
    });
  }
}

class HomePageBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut(() => HomeController());
  }
}
