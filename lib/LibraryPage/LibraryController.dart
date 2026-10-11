import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../models/LibrarySummary.dart';
import '../services/LikedController.dart';
import '../services/PlaylistEventsController.dart';
import '../services/repositories/LibraryRepository.dart';
import '../services/repositories/PlaylistRepository.dart';
import '../sdk/AuthController.dart';

enum LibraryTab {
  playlists(1, '歌单', Icons.playlist_play),
  albums(2, '专辑', Icons.album),
  artists(3, '艺人', Icons.person);

  const LibraryTab(this.id, this.label, this.icon);

  /// 网易云后端的 tab id (供 SDK / 个人中心等接口引用)
  final int id;

  final String label;
  final IconData icon;
}

/// Library 页 controller
///
/// 三个 tab 分别对应网易云"我的"：
/// - tab 1 (歌单): /user/playlist(uid)
/// - tab 2 (专辑): /album/sublist
/// - tab 3 (艺人): /user/follow/mixed(scene=1)
///
/// **未登录时**：不调接口，展示"请先登录"占位卡
class LibraryController extends GetxController {
  final Rx<LibraryTab> tab = LibraryTab.playlists.obs;
  Worker? _loginWorker;

  final LibraryRepository _repo = Get.find<LibraryRepository>();
  final PlaylistRepository _playlistRepo = Get.find<PlaylistRepository>();
  final LikedController _likedService = Get.find<LikedController>();
  final AuthController _auth = Get.find<AuthController>();

  // 创建歌单 UI 状态:isCreating 防止重复点 FAB 弹出多个 dialog;
  // createError 是上一次创建失败的提示。新歌单 id 不对外暴露,成功后
  // 重新 loadPlaylists 即可拿到(createPlaylist 成功后 SDK 已写盘)。
  final RxBool isCreating = false.obs;
  final RxnString createError = RxnString();

  // tab 1: 歌单
  final RxBool playlistsLoading = false.obs;
  final RxnString playlistsError = RxnString();
  final RxList<PlaylistSummary> playlists = <PlaylistSummary>[].obs;

  // tab 2: 专辑
  final RxBool albumsLoading = false.obs;
  final RxnString albumsError = RxnString();
  final RxList<AlbumSummary> albums = <AlbumSummary>[].obs;

  // tab 3: 艺人
  final RxBool artistsLoading = false.obs;
  final RxnString artistsError = RxnString();
  final RxList<ArtistSummary> artists = <ArtistSummary>[].obs;

  @override
  void onInit() {
    super.onInit();
    _loginWorker = ever(_auth.authInfo, (info) {
      if (info.loggedIn) {
        _loadVisibleTab();
      }
    });
    if (_auth.loggedIn) {
      _loadVisibleTab();
    }
  }

  void setTab(LibraryTab t) {
    tab.value = t;
    _loadVisibleTab();
  }

  void _loadVisibleTab() {
    switch (tab.value) {
      case LibraryTab.playlists:
        if (playlists.isEmpty && !playlistsLoading.value) loadPlaylists();
        break;
      case LibraryTab.albums:
        if (albums.isEmpty && !albumsLoading.value) loadAlbums();
        break;
      case LibraryTab.artists:
        if (artists.isEmpty && !artistsLoading.value) loadArtists();
        break;
    }
  }

  Future<void> loadPlaylists() async {
    if (playlistsLoading.value) return;
    playlistsLoading.value = true;
    playlistsError.value = null;
    final uid = _auth.currentUid;
    if (uid == 0) {
      playlistsLoading.value = false;
      return;
    }
    final list = await _repo.fetchPlaylists(uid.toString());
    playlists.assignAll(list);
    // **重置 delta**:全量 reload 后 playlist.trackCount 是后端真值,
    // 本地累计的 delta 已包含在新值里 —— 不重置会重复叠加 + 显示错。
    // 用 resetDelta 而不是 applyDelta(-X):不需要知道当前 delta 值。
    final events = Get.find<PlaylistEventsController>();
    for (final p in list) {
      events.resetDelta(p.id);
    }
    playlistsLoading.value = false;
  }

  Future<void> loadAlbums() async {
    if (albumsLoading.value) return;
    albumsLoading.value = true;
    albumsError.value = null;
    final list = await _repo.fetchSubscribedAlbums(_auth.currentUid.toString());
    albums.assignAll(list);
    albumsLoading.value = false;
  }

  Future<void> loadArtists() async {
    if (artistsLoading.value) return;
    artistsLoading.value = true;
    artistsError.value = null;
    final list = await _repo.fetchFollowedArtists(_auth.currentUid.toString());
    artists.assignAll(list);
    artistsLoading.value = false;
  }

  /// 查询某歌单 id 是否被当前用户收藏。调用方**必须包 Obx**才能响应 likedPlaylistIds 变化
  bool isPlaylistLiked(String playlistId) =>
      _likedService.isLiked(playlistId, LikedType.playlist);

  void togglePlaylistLike(String playlistId) {
    // ignore: discarded_futures
    _likedService.toggle(playlistId, LikedType.playlist);
  }

  bool isAlbumLiked(String albumId) =>
      _likedService.isLiked(albumId, LikedType.album);

  void toggleAlbumLike(String albumId) {
    // ignore: discarded_futures
    _likedService.toggle(albumId, LikedType.album);
  }

  bool isArtistLiked(String artistId) =>
      _likedService.isLiked(artistId, LikedType.artist);

  /// toggle 关注/取关艺人
  void toggleArtistLike(String artistId) {
    // ignore: discarded_futures
    _likedService.toggle(artistId, LikedType.artist);
  }

  /// 主动同步单点艺人的后端关注状态
  ///
  /// LibraryPage 关注艺人列表 card 首次 build 时调一次
  /// (Service 启动 loadAll 只拉 /artist/sublist 全量,单点 id 不在里面)
  Future<void> syncArtistFollowState(String artistId) {
    // ignore: discarded_futures
    return _likedService.syncArtistLike(artistId);
  }

  @override
  void onClose() {
    _loginWorker?.dispose();
    super.onClose();
  }

  /// 创建新歌单 —— 由 LibraryPage FAB 触发
  ///
  /// 流程:
  /// 1. 登录态自检(未登录直接 toast,不弹 dialog 免得用户输入完才发现没用)
  /// 2. 弹 AlertDialog 输入名字(空 / 取消 → 退出)
  /// 3. 调 [_playlistRepo.createPlaylist],成功 → loadPlaylists 刷新列表,
  ///    失败 → 写 [createError] 让 dialog 显示错误文案
  ///
  /// 声明成 `void ... async` 而不是 `Future<void>`:调用点是
  /// `IconButton.onPressed`(`VoidCallback?`),返回 Future 会被
  /// discarded_futures 警告,调用点已写 `// ignore: discarded_futures` 兜底。
  void addPlaylist() async {
    if (isCreating.value) return;
    if (!_auth.loggedIn) {
      Get.snackbar('提示', '请先登录');
      return;
    }
    final name = await _promptPlaylistName();
    if (name == null || name.isEmpty) return;

    isCreating.value = true;
    createError.value = null;
    try {
      final newId = await _playlistRepo.createPlaylist(name);
      if (newId == null) {
        createError.value = '创建失败,稍后重试';
        return;
      }
      await loadPlaylists();
    } finally {
      isCreating.value = false;
    }
  }

  /// 弹一个简单 AlertDialog 让用户输入歌单名字。返回名字,取消返回 `null`。
  Future<String?> _promptPlaylistName() async {
    // 注意：不要把 createError 用 Obx 放进这个 dialog。
    //
    // 这个 dialog 在用户点「创建/取消」后立即 pop，而 createError 只在
    // pop 之后的 addPlaylist() 里才会被写。Android 上 Get.dialog 的
    // Future 在 Navigator.pop 时就 complete（不等退场动画），此时 dialog
    // 的 Obx 如果还依赖外部 Rx，退场动画期间外部写 Rx 会触发已经
    // deactivating 的 InheritedElement rebuild，导致 framework 的
    // `_dependents.isEmpty` assertion。新建歌单的输入框本身不需要在这里
    // 显示错误——创建失败提示交给 SnackBar / 列表刷新处理。
    final controller = TextEditingController();
    final result = await Get.dialog<String>(
      AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '歌单名称'),
          onSubmitted: (_) => Get.back<String>(result: controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back<String>(result: null),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Get.back<String>(result: controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
      barrierDismissible: true,
    );

    // Android 上 Get.dialog 的 future 在 pop 时就 complete，但退场动画
    // 可能还在跑，TextField 仍持有这个 controller。直接 dispose 会在动画
    // 结束前释放 TextEditingController，触发 use-after-dispose。
    // 下一帧再释放，确保 dialog 完全退出。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.dispose();
    });

    return result;
  }
}

/// Library tab binding:跟 SearchPageBinding 同款,在 AppShell._bindingForTab 触发
class LibraryBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<LibraryController>(() => LibraryController());
  }
}
