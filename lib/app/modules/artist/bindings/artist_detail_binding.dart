import 'package:get/get.dart';

import '../../../data/models/library_summary.dart' show PlaylistSource;
import '../../song_list/bindings/song_list_detail_binding.dart';
import '../controllers/artist_controller.dart';

/// 艺人详情页 binding。
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
