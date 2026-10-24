import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../LibraryPage/library_controller.dart';
import '../models/library_summary.dart' show PlaylistSource;
import '../models/api_exception.dart';
import '../services/liked_controller.dart';
import '../services/repositories/album_repository.dart';
import '../services/repositories/artist_repository.dart';
import '../services/repositories/playlist_repository.dart';

/// 歌单 / 专辑 / 艺人详情页 head 行的公共基类。
///
/// **职责**:顶部 head 行的公共状态与命令 —— 标题、封面、描述、
/// `playlistSource`(决定按钮)、加载/错误状态,以及播放 / 收藏 / 删除按钮。
///
/// **不存**:歌曲列表 —— 那归 [SongListBodyController] 管。head / body 是
/// sibling controller,各存一份 `playlistId`(同一资源),可以分别销毁 / 重建。
///
/// 子类按资源类型决定元信息加载路径 + 收藏语义:[SongListHeadController] 歌单、
/// [AlbumHeadController] 专辑、[ArtistHeadController] 艺人。
abstract class SongListHeadControllerBase extends GetxController {
  SongListHeadControllerBase({
    required this.playlistId,
    required this.source,
    this.onPlayAll,
  });

  final String playlistId;

  /// 资源来源(专辑 / 歌单 / 艺人等)
  final PlaylistSource source;

  final LikedController _likedService = Get.find<LikedController>();

  // ---- head 行的 UI 状态 -----------------------------------------------------

  final RxnString title = RxnString();

  final RxnString coverUrl = RxnString();

  final RxnString description = RxnString();

  /// 资源来源(详情页唯一真相源)。构造时按 [source] 预填,加载后可被
  /// 后端响应覆盖。
  final Rxn<PlaylistSource> playlistSource = Rxn<PlaylistSource>();

  /// head 行整体加载状态(只反映元信息加载 —— 不反映歌曲列表加载)。
  final RxBool isLoading = false.obs;

  final RxnString errorMessage = RxnString();

  /// `ready` future:head 元信息拉完。外部可以 `await c.ready` 等首屏数据。
  late final Future<void> ready;

  /// 播放整张资源:head 只暴露 onPlayAll 钩子,由 binding 注入
  /// body controller 的具体实现 —— head 自己不知道 songs 在哪。
  Future<void> Function()? onPlayAll;

  /// 子类实现:拉元信息并写入 title / coverUrl / description /
  /// playlistSource。
  Future<void> loadMeta();

  /// 子类指定收藏类型:歌单 → playlist,专辑 → album,艺人 → artist。
  LikedType get likedType;

  /// 子类实现:删除语义。歌单可删,专辑 / 艺人不能删。
  Future<void> deletePlaylist();

  @override
  void onInit() {
    super.onInit();
    // 同步预填 source(后端响应不会反向覆盖它,见 SongListHeadController.loadMeta)
    playlistSource.value = source;
    ready = _runLoad();
  }

  Future<void> _runLoad() async {
    isLoading.value = true;
    errorMessage.value = null;
    try {
      await loadMeta();
    } on ApiException catch (e) {
      errorMessage.value = e.message;
    } finally {
      isLoading.value = false;
    }
  }

  /// 收藏 / 取消订阅。按子类的 [likedType] 分流。
  void toggleFavorite() {
    // ignore: discarded_futures
    _likedService.toggle(playlistId, likedType);
  }

  /// 查询当前资源是否被收藏(调用方必须包 Obx 才能响应变化)
  bool isPlaylistFavorite() {
    return _likedService.isLiked(playlistId, likedType);
  }

  /// 确认删除弹窗(仅自建歌单会走到)。
  Future<bool?> confirmDelete() {
    return Get.dialog<bool>(
      AlertDialog(
        title: const Text('删除歌单'),
        content: Text('确定要删除歌单"${title.value ?? ''}"吗?此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Get.back<bool>(result: false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Get.back<bool>(result: true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
      barrierDismissible: true,
    );
  }
}

/// 歌单详情页 head 行 controller:`created` / `collected` / `pure` 三种歌单分支,
/// 元信息走 [PlaylistRepository.fetchMeta],收藏走 [LikedType.playlist],
/// 仅自建歌单(created)可删除。
class SongListHeadController extends SongListHeadControllerBase {
  SongListHeadController({
    required super.playlistId,
    required super.source,
    super.onPlayAll,
  });

  final PlaylistRepository _playlistRepo = Get.find<PlaylistRepository>();

  @override
  LikedType get likedType => LikedType.playlist;

  @override
  Future<void> loadMeta() async {
    final meta = await _playlistRepo.fetchMeta(playlistId);
    if (meta != null) {
      title.value = meta.name;
      coverUrl.value = meta.coverUrl;
      description.value = meta.description;
      // 不覆盖 playlistSource：source 由 binding 传入并决定详情页按钮语义
      // （created → 删除，collected/pure → 收藏）。后端 subscribed 只用于
      // PlaylistMeta 内部描述，不再反向覆盖这里的 source。
    }
    // meta 失败 → playlistSource 保持 source,widget 按原 source 渲染按钮
  }

  @override
  Future<void> deletePlaylist() async {
    final confirmed = await confirmDelete();
    if (confirmed != true) return;

    final ok = await _playlistRepo.deletePlaylist(playlistId);
    if (!ok) {
      Get.snackbar('删除失败', '稍后重试');
      return;
    }
    // reload Library 列表(LazyPut 可能未注册,守卫)
    if (Get.isRegistered<LibraryController>()) {
      await Get.find<LibraryController>().loadPlaylists();
    }
    final ctx = Get.context;
    if (ctx != null && ctx.mounted && Navigator.of(ctx).canPop()) {
      Navigator.of(ctx).pop();
    }
  }
}

/// 专辑详情页 head 行 controller:元信息走 [AlbumRepository.fetch](忽略返回的
/// songs),收藏走 [LikedType.album],不可删除。
class AlbumHeadController extends SongListHeadControllerBase {
  AlbumHeadController({
    required super.playlistId,
    required super.source,
    super.onPlayAll,
  });

  final AlbumRepository _albumRepo = Get.find<AlbumRepository>();

  @override
  LikedType get likedType => LikedType.album;

  @override
  Future<void> loadMeta() async {
    final content = await _albumRepo.fetch(playlistId);
    if (content != null) {
      title.value = content.name;
      coverUrl.value = content.coverUrl;
      description.value = content.description;
    }
    // fetch 失败 → title/coverUrl/description 保持 null,widget 显示空
  }

  @override
  Future<void> deletePlaylist() async {
    Get.snackbar('提示', '专辑不能删除');
  }
}

/// 艺人详情页 head 行 controller:元信息走 [ArtistRepository.fetchArtist],
/// 收藏(关注)走 [LikedType.artist],不可删除。
///
/// 注意:艺人详情页目前走 [ArtistController],本类仅在 source == artist 时
/// 由 SongListDetailBinding 创建。
class ArtistHeadController extends SongListHeadControllerBase {
  ArtistHeadController({
    required super.playlistId,
    required super.source,
    super.onPlayAll,
  });

  final ArtistRepository _artistRepo = Get.find<ArtistRepository>();

  @override
  LikedType get likedType => LikedType.artist;

  @override
  Future<void> loadMeta() async {
    final info = await _artistRepo.fetchArtist(playlistId);
    if (info != null) {
      title.value = info.artist.name;
      coverUrl.value = info.artist.photoUrl;
      description.value = info.artist.bio;
    }
  }

  @override
  Future<void> deletePlaylist() async {
    Get.snackbar('提示', '艺人不能删除');
  }
}
