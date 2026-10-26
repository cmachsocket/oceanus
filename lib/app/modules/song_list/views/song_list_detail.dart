import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/constants/default_values.dart';
import '../../../data/models/library_summary.dart' show PlaylistSource;
import '../bindings/song_list_body_binding.dart';
import '../widgets/song_list_body.dart';
import '../widgets/song_list_head.dart';
import '../controllers/song_list_head_controller.dart';

/// 歌单详情页(主页 [SongListCard] 点进来后看到)
///
/// - 由 binding 同时注入两个 sibling controller:
///   - [SongListHeadController]:head 行(标题/封面/描述/playlistSource/按钮命令)
///   - [SongListBodyController]:body(歌曲列表 + 加载/错误)
/// - widget 层只组合 [SongListHead] + [SongListBody],不直接 Get.find controller。
/// - 业务侧零硬编码 —— 列表渲染 / 单元格都走现成 widget。
class SongListDetail extends StatelessWidget {
  const SongListDetail({
    super.key,
    this.displayTitle,
    required this.controllerTag,
  });

  /// 进入页面时 fallback 标题(head controller 拉完元信息后会覆盖)
  final String? displayTitle;
  final String controllerTag;

  @override
  Widget build(BuildContext context) {
    final head = Get.find<SongListHeadControllerBase>(tag: controllerTag);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Get.back(id: DefaultValues.shellNavigatorId),
          icon: const Icon(Icons.arrow_back),
        ),
        title: Obx(() {
          // 优先用 head 拉到的 title;没拉到时用 displayTitle 兜底
          final remoteTitle = head.title.value?.trim() ?? '';
          final fallbackTitle = displayTitle?.trim() ?? '歌单';
          final title = remoteTitle.isNotEmpty ? remoteTitle : fallbackTitle;
          final prefix = switch (head.playlistSource.value) {
            PlaylistSource.album => '专辑',
            PlaylistSource.artist => '艺人',
            _ => '歌单',
          };
          return Text('$prefix · $title');
        }),
      ),
      body: Column(
        children: [
          SongListHead(controllerTag: head.playlistId + head.source.toString()),
          Expanded(
            child: //嵌套导航
            Navigator(
              initialRoute: '/songlistbody',
              onGenerateRoute: (settings) {
                if (settings.name == '/songlistbody') {
                  return GetPageRoute(
                    page: () => SongListBody(
                      controllerTag: head.playlistId + head.source.toString(),
                    ),
                    binding: SongListBodyBinding(
                      playlistId: head.playlistId,
                      source: head.source,
                    ),
                  );
                }
                return null;
              },
            ),
          ),
        ],
      ),
    );
  }
}
