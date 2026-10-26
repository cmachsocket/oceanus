import 'dart:async' show unawaited;

import 'package:flutter/widgets.dart' show TextEditingController;
import 'package:get/get.dart';

import '../../../data/models/album.dart';
import '../../../data/models/song.dart';
import '../../../data/models/artist.dart';
import '../../../services/liked_controller.dart';
import '../../../services/audio_player_wrapper.dart';
import '../../../data/repositories/search_repository.dart';
import '../../../data/repositories/song_repository.dart';

/// 搜索页 controller
///
/// - 4 个 [SearchType] 各自维护一份结果(切 tab 不丢旧结果)
/// - [search] 调 [SearchRepository.search],**只查当前 type**(省钱 + 响应快)
/// - [setType] 切 tab 时如果有当前 keyword 就**自动重搜**(旧结果跨 type 不能复用)
class SearchController extends GetxController {
  final Rx<SearchType> type = SearchType.song.obs;

  final AudioPlayerService queue = Get.find<AudioPlayerService>();
  final LikedController _likedService = Get.find<LikedController>();
  final SongRepository _songRepo = Get.find<SongRepository>();
  final SearchRepository _searchRepo = Get.find<SearchRepository>();

  /// TextField 的真实数据源 —— 必须显式绑给 [TextField.controller],
  /// 否则点清除按钮时 [TextField] 内部 state 复用了看不见的 TextEditingController,
  /// keyword 变空但输入框不会清空(看起来没反应)
  final TextEditingController textController = TextEditingController();

  /// 当前输入框的关键词 (TextField onChanged 同步,只反映输入框文本)
  ///
  /// **不要**用这个判"是否搜过"——用户键入字符 keyword 就变,但还没提交。
  /// 判"搜过"请用 [submittedKeyword](只有 search() 调用时才写)。
  final RxString keyword = ''.obs;

  /// 已提交的关键词(search() 调用时写入)。跟 [keyword] 解耦:实时输入不影响
  /// 结果视图。判"未搜过"用 `submittedKeyword.value.isEmpty`,避开
  /// "键入几个字符但没提交"的陷阱。
  final RxString submittedKeyword = ''.obs;

  /// 4 份结果(切 tab 不丢;只有同 type 才覆盖)
  final RxList<Song> songResults = <Song>[].obs;
  final RxList<Album> albumResults = <Album>[].obs;
  final RxList<Artist> artistResults = <Artist>[].obs;
  final RxList<SearchPlaylistSummary> playlistResults =
      <SearchPlaylistSummary>[].obs;

  final RxBool isLoading = false.obs;
  final RxnString errorMessage = RxnString();

  @override
  void onClose() {
    textController.dispose();
    super.onClose();
  }

  void setKeyword(String k) => keyword.value = k;

  void clearKeyword() {
    textController.clear();
    keyword.value = '';
    submittedKeyword.value = ''; // 同步清提交状态,UI 回"输入关键词"提示
    _clearCurrent();
  }

  /// 切换 tab:有 keyword 就自动重搜,空 keyword 直接清空对应结果。
  ///
  /// 读 [keyword](输入框文本)而非 [submittedKeyword]——用户键入了字但没提交,
  /// 切 tab 时按输入框内容重搜,符合"用户期望"。
  void setType(SearchType t) {
    type.value = t;
    final k = keyword.value.trim();
    if (k.isEmpty) {
      _clearCurrent();
    } else {
      search(k);
    }
  }

  void _clearCurrent() {
    switch (type.value) {
      case SearchType.song:
        songResults.clear();
      case SearchType.album:
        albumResults.clear();
      case SearchType.artist:
        artistResults.clear();
      case SearchType.playlist:
        playlistResults.clear();
    }
  }

  /// 触发搜索(只查当前 [type] 的结果)。
  Future<void> search(String keyword) async {
    final k = keyword.trim();
    this.keyword.value = k;
    if (k.isEmpty) {
      _clearCurrent();
      submittedKeyword.value = '';
      return;
    }
    submittedKeyword.value = k;
    isLoading.value = true;
    errorMessage.value = null;
    final t = type.value;
    final result = await _searchRepo.search(keywords: k, type: t);
    if (result == null) {
      errorMessage.value = '搜索失败';
      Get.snackbar('搜索失败', '请稍后再试', snackPosition: SnackPosition.BOTTOM);
      isLoading.value = false;
      return;
    }
    _storeResult(result);
    if (t == SearchType.song) {
      // 单曲封面补图:search 接口 album 项只有 picId(数字),没 picUrl(URL)。
      unawaited(enrichSongCovers());
    }
    isLoading.value = false;
  }

  /// 按 type 写对应 RxList (其他类型置空)
  void _storeResult(SearchResult r) {
    switch (type.value) {
      case SearchType.song:
        songResults.assignAll(r.songs ?? <Song>[]);
        // 跨 type 的旧结果不复用,统一清空
        albumResults.clear();
        artistResults.clear();
        playlistResults.clear();
      case SearchType.album:
        albumResults.assignAll(r.albums ?? <Album>[]);
        songResults.clear();
        artistResults.clear();
        playlistResults.clear();
      case SearchType.artist:
        artistResults.assignAll(r.artists ?? <Artist>[]);
        songResults.clear();
        albumResults.clear();
        playlistResults.clear();
      case SearchType.playlist:
        playlistResults.assignAll(r.playlists ?? <SearchPlaylistSummary>[]);
        songResults.clear();
        albumResults.clear();
        artistResults.clear();
    }
  }

  /// 单曲封面补图
  ///
  /// - **背景**:`/search?type=1` 返回的 songs[].album 只给 `picId`(数字),
  ///   不给 `picUrl`(URL);`Image.network("数字串")` 解析 URI 失败 → 占位
  /// - **做法**:批量调 [SongRepository.fetchSongDetails] 拿真 URL,按 songId
  ///   回填。Song.coverUrl 是 `final` 不可变 → 重建 Song 对象 + assignAll。
  ///   补图失败静默(不阻塞搜索结果,UI 走占位)
  /// - **竞争**:用户已切走 / 清空时按 id 匹配不上就不动 → 安全
  Future<void> enrichSongCovers() async {
    final snapshot = songResults.toList();
    if (snapshot.isEmpty) return;
    final byId = await _songRepo.fetchSongDetails(
      snapshot.map((s) => s.id).toList(),
    );
    if (byId.isEmpty) return;
    // 按当前 songResults 重建(若 songResults 已被换走,以当前为准,旧 id 跳过)
    final updated = <Song>[];
    var changed = false;
    for (final s in songResults) {
      final newCover = byId[s.id];
      if (newCover != null && newCover != s.coverUrl) {
        updated.add(
          Song(
            id: s.id,
            title: s.title,
            artist: s.artist,
            artistId: s.artistId,
            album: s.album,
            albumId: s.albumId,
            coverUrl: newCover,
            duration: s.duration,
          ),
        );
        changed = true;
      } else {
        updated.add(s);
      }
    }
    if (changed) songResults.assignAll(updated);
  }

  bool isAlbumLiked(String albumId) =>
      _likedService.isLiked(albumId, LikedType.album);

  bool isArtistLiked(String artistId) =>
      _likedService.isLiked(artistId, LikedType.artist);

  bool isPlaylistLiked(String playlistId) =>
      _likedService.isLiked(playlistId, LikedType.playlist);

  void toggleAlbumLike(String albumId) {
    // ignore: discarded_futures
    _likedService.toggle(albumId, LikedType.album);
  }

  void toggleArtistLike(String artistId) {
    // ignore: discarded_futures
    _likedService.toggle(artistId, LikedType.artist);
  }

  void togglePlaylistLike(String playlistId) {
    // ignore: discarded_futures
    _likedService.toggle(playlistId, LikedType.playlist);
  }

  void syncArtistLike(String artistId) {
    // ignore: discarded_futures
    _likedService.syncArtistLike(artistId);
  }

  /// 单曲点赞/收藏转发(搜索结果的 SongListBody 需要),走 [LikedType.song]
  void toggleFavorite(String songId) {
    // ignore: discarded_futures
    _likedService.toggle(songId, LikedType.song);
  }

  /// 查询单曲点赞状态。调用方需要包 Obx 才能响应 likedSongIds 变化
  bool isLiked(String songId) => _likedService.isLiked(songId, LikedType.song);

  /// 把当前搜索结果当播放队列,从这首开始播放(搜索结果 limit 30)
  Future<void> playSong(Song song) {
    return queue.playSongs(songResults.toList(), startSong: song);
  }
}
