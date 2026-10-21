import 'package:get/get.dart';

import '../models/album.dart';
import '../models/api_exception.dart';
import '../services/liked_controller.dart';
import '../services/repositories/artist_repository.dart';

/// ArtistDetail 页面专属 controller —— 管"专辑 / 歌曲"切换 + 专辑列表 +
/// 单张专辑收藏(复用全局 [LikedController],LikedType.album,不引入新存储)。
///
/// **不存**:艺人元信息(头像 / 简介 / 关注 / 播放全部)归 head controller,
/// 歌曲列表归 [SongListBodyController]。本 controller 只管 view 状态 +
/// 专辑列表 + 专辑收藏。
///
/// **与 head / body 的关系**:三个 controller 共用同一 `controllerTag`,
/// 在 [ArtistDetailBinding] 时一起注入。
class ArtistController extends GetxController {
  ArtistController({required this.artistId});

  final String artistId;

  // ---- 依赖 -----------------------------------------------------------------

  final ArtistRepository _artistRepo = Get.find<ArtistRepository>();
  final LikedController _likedService = Get.find<LikedController>();

  // ---- 视图切换 -------------------------------------------------------------

  final Rx<ArtistView> view = ArtistView.albums.obs;

  void setView(ArtistView v) {
    if (view.value == v) return;
    view.value = v;
  }

  // ---- 专辑 / EP 列表 -------------------------------------------------------

  final RxList<Album> albums = <Album>[].obs;
  final RxBool isAlbumsLoading = false.obs;
  final RxnString albumsError = RxnString();

  @override
  void onInit() {
    super.onInit();
    _loadAlbums();
  }

  Future<void> _loadAlbums() async {
    isAlbumsLoading.value = true;
    albumsError.value = null;
    try {
      final list = await _artistRepo.fetchAlbums(artistId);
      albums.assignAll(list);
    } on ApiException catch (e) {
      albumsError.value = e.message;
      albums.clear();
    } catch (e) {
      albumsError.value = '加载专辑失败: $e';
      albums.clear();
    } finally {
      isAlbumsLoading.value = false;
    }
  }

  // ---- 单张专辑收藏 ---------------------------------------------------------

  bool isAlbumLiked(String albumId) =>
      _likedService.isLiked(albumId, LikedType.album);

  void toggleAlbumFavorite(String albumId) {
    // ignore: discarded_futures
    _likedService.toggle(albumId, LikedType.album);
  }
}

/// ArtistDetail 的视图切换 enum。放在本文件而不进 models/:只有这个
/// controller 用,不需要全局暴露。
enum ArtistView { albums, songs }
