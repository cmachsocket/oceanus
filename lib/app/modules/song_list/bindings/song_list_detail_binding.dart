import 'package:get/get.dart';

import '../../../data/models/library_summary.dart' show PlaylistSource;
import '../controllers/song_list_body_controller.dart';
import '../controllers/song_list_head_controller.dart';

/// 歌单详情页 binding —— 同时注入 head / body 两个 controller。
///
/// **单向关联**:head 的 `onPlayAll` 指向 body 的 `playAll`,这样 head 是
/// 纯命令执行器,不知道 songs 在哪(解耦)。其它 head 命令(toggleFavorite /
/// isPlaylistFavorite / deletePlaylist)只跟全局服务交互,不依赖 body。
class SongListDetailBinding extends Bindings {
  SongListDetailBinding({required this.playlistId, required this.source});

  final String playlistId;
  final PlaylistSource source;

  SongListHeadControllerBase _buildHead(SongListBodyController body) {
    return switch (source) {
      PlaylistSource.album => AlbumHeadController(
        playlistId: playlistId,
        source: source,
        onPlayAll: body.playAll,
      ),
      PlaylistSource.artist => ArtistHeadController(
        playlistId: playlistId,
        source: source,
        onPlayAll: body.playAll,
      ),
      PlaylistSource.created ||
      PlaylistSource.collected ||
      PlaylistSource.pure => SongListHeadController(
        playlistId: playlistId,
        source: source,
        onPlayAll: body.playAll,
      ),
    };
  }

  @override
  void dependencies() {
    final body = SongListBodyController(playlistId: playlistId, source: source);
    Get.lazyPut<SongListBodyController>(
      () => body,
      tag: playlistId.toString() + source.toString(),
    );
    Get.lazyPut<SongListHeadControllerBase>(
      () => _buildHead(body),
      tag: playlistId.toString() + source.toString(),
    );

    // 把 body.playAll 注入 head 的 onPlayAll 钩子(head 不知道 body 的存在,
    // 只接一个 Future<void> Function())
  }
}

/// 不带参数的老 binding 占位(其它地方可能 import 这个名字)。
/// 之前 [SongListBinding] 是空类 —— 删掉,统一用 [SongListDetailBinding]。
class SongListBinding extends Bindings {
  @override
  void dependencies() {
    // 参数由 [SongListDetailBinding] 携带,这里 no-op。
  }
}
