import 'dart:async';

import 'package:get/get.dart';

/// 全局播放列表事件中心。
///
/// 歌单曲目变化(`addTracks` / `removeTracks` / `deletePlaylist`)是跨页面事件,
/// 所有显示同一歌单 trackCount 的地方都要跟着更新。delta 累加而不是覆盖:
/// 连续 addTracks(+1,+1,+1) 显示为 +3。
class PlaylistEventsController extends GetxController {
  final RxMap<String, int> _deltas = <String, int>{}.obs;

  final StreamController<PlaylistTrackChangedEvent> _trackChangedCtrl =
      StreamController<PlaylistTrackChangedEvent>.broadcast();

  /// 给不想用 Obx、想用 StreamBuilder 的 widget 用。不想监听 stream 就直接读
  /// [deltaFor] 包 Obx。
  Stream<PlaylistTrackChangedEvent> get onTrackChanged =>
      _trackChangedCtrl.stream;

  /// 本地 delta(累加值)。调用方包 Obx 才能响应变化。
  int deltaFor(String playlistId) => _deltas[playlistId] ?? 0;

  /// n>0 加歌,n<0 减歌,n=0 归零(删除歌单)。
  void applyDelta(String playlistId, int n) {
    if (n == 0) return;
    _deltas[playlistId] = (_deltas[playlistId] ?? 0) + n;
    _trackChangedCtrl.add(
      PlaylistTrackChangedEvent(playlistId: playlistId, delta: n),
    );
  }

  /// 后端重新拉到 base count 后清零,widget 才会显示最新值。
  void resetDelta(String playlistId) {
    _deltas[playlistId] = 0;
  }

  @override
  void onClose() {
    _trackChangedCtrl.close();
    super.onClose();
  }
}

class PlaylistTrackChangedEvent {
  const PlaylistTrackChangedEvent({
    required this.playlistId,
    required this.delta,
  });
  final String playlistId;
  final int delta;
}
