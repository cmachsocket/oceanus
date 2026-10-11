import 'package:get/get.dart';

import '../models/Snapshot.dart' show PlaybackSnapshot;
import '../models/Song.dart';
import '../services/AudioPlayerWrapper.dart';

enum CenterPage { cover, lyric }

/// 播放页 UI 控制器:wrapper.snapshot 的薄 facade,只做镜像 + 命令转发 +
/// center 切页(纯 UI 状态)。不持有任何音频事实状态。
///
/// **故意不 `permanent: true`**:跨路由 push/pop 时 GetX 会销毁重建,重建成本
/// 极低(onInit 里 ever 立刻从 snapshot 镜像一次),UI 始终看到 wrapper 的实时值。
/// (LyricsController 要 permanent 是因为 flutter_lyric 的 LyricController 持有
/// 高亮位置 / 已加载 lyric 这类 state,本 controller 只是镜像。)
class PlayerController extends GetxController {
  // region UI facade:从 wrapper 镜像过来(UI 端无感)
  final Rx<Duration> position = Duration.zero.obs;
  final Rx<Duration> duration = Duration.zero.obs;
  final Rx<Duration> buffered = Duration.zero.obs;
  final RxBool isPlaying = false.obs;

  final Rxn<Song> currentSong = Rxn<Song>();

  /// 镜像 snapshot.isCurrentSongLiked(handler 推流,本层不订阅 LikedController)
  final RxBool isLiked = false.obs;
  // endregion

  final Rx<CenterPage> center = CenterPage.cover.obs;

  final AudioPlayerService _audio = Get.find<AudioPlayerService>();

  Worker? _snapshotWorker;

  @override
  void onInit() {
    super.onInit();
    _snapshotWorker = ever<PlaybackSnapshot>(_audio.snapshot, _onSnapshot);
    _onSnapshot(_audio.snapshot.value);
  }

  @override
  void onClose() {
    _snapshotWorker?.dispose();
    super.onClose();
  }

  void _onSnapshot(PlaybackSnapshot s) {
    isPlaying.value = s.isPlaying;
    position.value = s.position;
    buffered.value = s.bufferedPosition;
    currentSong.value = s.currentSong;
    isLiked.value = s.isCurrentSongLiked;

    // 当前歌 duration 优先取 snapshot.currentSong —— wrapper._itemToSong 把
    // MediaItem.duration 翻了进来,而那是 handler 从 just_audio durationStream
    // 实时维护的(切歌后会经历 0 → 真值两次 emit)。
    // currentSong 还没 emit 时用 playlist 占位(Song 元数据,可能略不准)。
    if (s.currentSong != null) {
      duration.value = s.currentSong!.duration;
    } else if (_audio.playlist.isNotEmpty &&
        _audio.currentIndex.value >= 0 &&
        _audio.currentIndex.value < _audio.playlist.length) {
      duration.value = _audio.playlist[_audio.currentIndex.value].duration;
    } else {
      duration.value = Duration.zero;
    }
  }

  // region 命令转发(UI 调用)

  void selectIndex(int index) => _audio.selectIndex(index);
  void next() => _audio.skipToNext();
  void prev() => _audio.skipToPrevious();
  // endregion

  void play() => _audio.play();
  void pause() => _audio.pause();
  void togglePlay() => isPlaying.value ? pause() : play();
  void seek(Duration p) => _audio.seek(p);

  void switchPage() {
    center.value = switch (center.value) {
      CenterPage.cover => CenterPage.lyric,
      CenterPage.lyric => CenterPage.cover,
    };
  }

  /// 走 wrapper 集中依赖(不直接 Get.find<LikedController>),linked 同步由
  /// handler 推流链路自动完成。没有当前歌曲时 no-op。
  void toggleFavorite() {
    final song = currentSong.value;
    if (song == null) return;
    // ignore: discarded_futures
    _audio.toggleFavorite(song.id);
  }
}
