import 'package:get/get.dart';

import '../../../data/models/library_summary.dart' show PlaylistSource;
import '../controllers/song_list_body_controller.dart';

/// 歌单 body 绑定。
class SongListBodyBinding extends Bindings {
  SongListBodyBinding({
    required this.playlistId,
    required this.source,
    this.loadSongsCustom,
  });
  final String playlistId;
  final PlaylistSource source;

  /// 可选:body controller 的自定义加载钩子。
  /// 用例:搜索结果(数据在 SearchController.songResults,不再调后端)。
  final void Function(SongListBodyController)? loadSongsCustom;

  @override
  void dependencies() {
    Get.lazyPut<SongListBodyController>(
      () => SongListBodyController(
        playlistId: playlistId,
        source: source,
        loadSongsCustom: loadSongsCustom,
      ),
      tag: playlistId.toString() + source.toString(),
    );
  }
}
