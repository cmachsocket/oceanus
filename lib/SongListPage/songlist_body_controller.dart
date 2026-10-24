import 'package:get/get.dart';

import '../models/song.dart';
import '../services/liked_controller.dart';
import '../services/audio_player_wrapper.dart';
import '../models/api_exception.dart';
import 'long_press_dialog.dart';
import '../services/repositories/album_repository.dart';
import '../services/repositories/artist_repository.dart';
import '../services/repositories/playlist_repository.dart';
import '../models/library_summary.dart' show PlaylistSource;

/// 歌单详情页 body 区 controller:歌曲列表 + 加载状态 + 错误信息。
///
/// 跟 head 是 sibling controller,各存一份 `playlistId`、完全独立;binding 时同时
/// 注入,head 的 `onPlayAll` 钩子指向 body.playAll,head 不需要知道 body 的实现。
/// head 行的标题 / 封面 / 描述 / source 归 [SongListHeadController]。
class SongListBodyController extends GetxController {
  SongListBodyController({
    required this.playlistId,
    required this.source,
    this.loadSongsCustom,
  });

  final String playlistId;
  final PlaylistSource source;

  /// 自定义加载钩子(搜索结果等有外部数据源的场景)。
  ///
  /// 责任:① 立即给 `body.songs` 赋值;② 可选调 [watchExternal] 让外部 Rx 变化
  /// 自动同步到 `body.songs`。
  ///
  /// 必须是 **sync**:`_loadSongs` 走 `Future.microtask`,async 钩子会多占一层。
  ///
  /// 禁止:`Get.find(tag: ...)`(onInit 同步链里调同 tag 的 find 会让 GetX
  /// reentrant 状态错乱)、同步阻塞的网络请求(该走 `_loadSongs` 默认分支)。
  final void Function(SongListBodyController)? loadSongsCustom;

  /// onClose 时统一 dispose,否则 controller 已销毁而 Worker 仍回调。
  final List<Worker> _workers = [];

  /// 把外部 `RxList<Song>` 的变化自动 assignAll 到 `body.songs`(配
  /// [loadSongsCustom] 使用)。RxList 没有主从概念只能手动 assignAll,`ever`
  /// 的 Worker 生命周期跟 controller 走。
  void watchExternal(RxList<Song> external, RxList<Song> target) {
    _workers.add(
      ever<List<Song>>(external, (List<Song> updated) {
        target.assignAll(updated);
      }),
    );
  }

  final AudioPlayerService _queue = Get.find<AudioPlayerService>();
  final LikedController _likedService = Get.find<LikedController>();
  final PlaylistRepository _playlistRepo = Get.find<PlaylistRepository>();
  final AlbumRepository _albumRepo = Get.find<AlbumRepository>();
  final ArtistRepository _artistRepo = Get.find<ArtistRepository>();

  /// 歌曲列表(来自 /playlist/track/all 或 /album)
  final RxList<Song> songs = <Song>[].obs;

  /// body 加载状态(独立于 head 的 isLoading —— 元信息 / 歌曲列表可能错开)
  final RxBool isLoading = false.obs;

  /// body 加载失败(head 失败不影响 body 显示,反之亦然)
  final RxnString errorMessage = RxnString();

  /// body 拉完首屏歌曲。外部 `await c.ready` 等首屏数据。
  ///
  /// 必须是 `late` 而不是 `late final`:onInit 可能被再次触发,`late final`
  /// 第二次赋值会抛 Field already initialized。
  late Future<void> ready;

  @override
  void onInit() {
    super.onInit();
    // 必须推迟到 microtask:loadSongsCustom 里同步写 Rx 会立刻通知内部 Obx
    // rebuild,而 onInit 是被 Get.put 的同步创建链调用的 —— 那会让 widget tree
    // 在构造过程中被 reentrant 更新。
    ready = Future.microtask(_loadSongs);
  }

  @override
  void onClose() {
    for (final w in _workers) {
      w.dispose();
    }
    _workers.clear();
    super.onClose();
  }

  /// 拉曲目:`loadSongsCustom` 优先,否则按 [source] 分流。
  Future<void> _loadSongs() async {
    isLoading.value = true;
    errorMessage.value = null;
    try {
      // 自定义钩子优先(用例:搜索结果直接用 SearchController.songResults)
      if (loadSongsCustom != null) {
        loadSongsCustom!(this);
        return;
      }
      switch (source) {
        case PlaylistSource.pure:
          // 实际场景不会走到(总有自定义钩子),兜底走 playlist 路径
          await _loadPlaylistSongs(playlistId);
        case PlaylistSource.album:
          await _loadAlbumSongs(playlistId);
        case PlaylistSource.artist:
          await _loadArtistSongs(playlistId);
        case PlaylistSource.created:
        case PlaylistSource.collected:
          await _loadPlaylistSongs(playlistId);
      }
    } on ApiException catch (e) {
      errorMessage.value = e.message;
    } finally {
      isLoading.value = false;
    }
  }

  /// 歌单分支:`/playlist/track/all?id=X`
  Future<void> _loadPlaylistSongs(String id) async {
    final fetched = await _playlistRepo.fetchTracks(id);
    songs.assignAll(fetched);
  }

  /// 专辑分支:`/album?id=X`(响应同时含 album 项 + songs 数组,一次拿全)
  Future<void> _loadAlbumSongs(String id) async {
    final content = await _albumRepo.fetch(id);
    if (content == null) {
      throw ApiException(0, '专辑内容拉取失败');
    }
    songs.assignAll(content.songs);
  }

  /// 艺人分支:`/artist/songs?id=X`(艺人所有歌曲)
  Future<void> _loadArtistSongs(String id) async {
    final fetched = await _artistRepo.fetchSongs(id);
    songs.assignAll(fetched);
  }

  // ---- body 命令 ------------------------------------------------------------

  /// 播放整张歌单:head 的 onPlayAll 钩子指向这里。
  Future<void> playAll() {
    return _queue.playSongs(songs.toList());
  }

  /// 播放某首歌:从这首开始播整张歌单。
  Future<void> playSong(Song song) {
    return _queue.playSongs(songs.toList(), startSong: song);
  }

  /// toggle 单首歌的喜欢状态(每首歌是 song 类型 LikedType)。
  void toggleFavorite(String songId) {
    // ignore: discarded_futures
    _likedService.toggle(songId, LikedType.song);
  }

  void onSongLongPress(Song song, int index) {
    Get.dialog(
      GetBuilder<LongPressDialogController>(
        tag: 'longPressDialog',
        init: LongPressDialogController(
          song: song,
          index: index,
          source: source,
          playlistId: playlistId,
        ),
        builder: (_) => const LongPressDialog(),
      ),
    );
  }

  /// 查询某首歌是否被喜欢(调用方必须包 Obx 才能响应变化)
  bool isLiked(String songId) => _likedService.isLiked(songId, LikedType.song);

  /// 按 [playlistId] 拉歌 + 整张播放,给卡片"播放"按钮用(不进详情页)。
  /// 临时 put 一个实例,等首屏 load 完 → playAll → 销毁。
  static Future<void> playPlaylistById(String playlistId) async {
    final tag = 'preview-$playlistId';
    if (Get.isRegistered<SongListBodyController>(tag: tag)) {
      Get.delete<SongListBodyController>(tag: tag);
    }
    final c = Get.put(
      SongListBodyController(
        playlistId: playlistId,
        source: PlaylistSource.pure,
      ),
      tag: tag,
    );
    await c.ready;
    if (c.songs.isNotEmpty) await c.playAll();
    Get.delete<SongListBodyController>(tag: tag);
  }
}
