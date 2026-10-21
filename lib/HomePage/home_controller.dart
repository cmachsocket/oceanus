import 'package:get/get.dart';

import '../models/library_summary.dart';
import '../services/liked_controller.dart';
import '../services/repositories/library_repository.dart';

/// 首页 controller
///
/// - **推荐歌单**:调 /personalized(无需登录),默认拉 30 张
/// - **每日推荐 / 私人 FM**:需登录,占位入口
class HomeController extends GetxController {
  final RxBool isLoading = false.obs;
  final RxnString errorMessage = RxnString();

  final LibraryRepository _repo = Get.find<LibraryRepository>();
  final LikedController _likedController = Get.find<LikedController>();

  final RxList<PlaylistCard> recommended = <PlaylistCard>[].obs;

  @override
  void onInit() {
    super.onInit();
    load();
  }

  Future<void> load() async {
    isLoading.value = true;
    errorMessage.value = null;
    final list = await _repo.fetchPersonalized();
    recommended.assignAll(list);
    isLoading.value = false;
  }

  /// 调用方**必须包 Obx**才能响应 likedPlaylistIds 变化
  bool isPlaylistLiked(String playlistId) =>
      _likedController.isLiked(playlistId, LikedType.playlist);

  void togglePlaylistLike(String playlistId) {
    // ignore: discarded_futures
    _likedController.toggle(playlistId, LikedType.playlist);
  }
}
