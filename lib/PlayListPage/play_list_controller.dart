import 'package:get/get.dart';
import '../models/snapshot.dart' show PlayOrder;
import '../models/song.dart';
import '../services/liked_controller.dart';
import '../services/audio_player_wrapper.dart';

/// 播放列表页 controller。队列数据全权由 [AudioPlayerService] 维护,
/// 这里只做转发;喜欢状态走全局 [LikedController],不绑在播放队列上。
class PlayListController extends GetxController {
  final AudioPlayerService queue = Get.find<AudioPlayerService>();
  final LikedController _likedService = Get.find<LikedController>();

  RxList<Song> get playlist => queue.playlist;
  RxInt get currentIndex => queue.currentIndex;
  Rx<PlayOrder> get mode => queue.mode;

  void selectIndex(int index) => queue.selectIndex(index);
  void setMode(PlayOrder m) => queue.setPlayOrder(m);
  int nextIndex() => queue.nextIndex();
  int prevIndex() => queue.prevIndex();
  Future<void> playSong(Song song) => queue.playSong(song);
  Future<void> playSongs(List<Song> songs, {Song? startSong}) =>
      queue.playSongs(songs, startSong: startSong);
  void removeSong(int index) => queue.removeSong(index);

  void toggleFavorite(String songId) {
    // ignore: discarded_futures
    _likedService.toggle(songId, LikedType.song);
  }

  /// 调用方**必须包 Obx** 才能响应 likedSongIds 变化。
  bool isLiked(String songId) => _likedService.isLiked(songId, LikedType.song);
}
