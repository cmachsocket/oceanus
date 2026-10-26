import 'package:get/get.dart';

import '../../../core/constants/default_values.dart';
import '../controllers/play_list_controller.dart';

/// 播放列表页 binding。
class PlayListBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<PlayListController>(
      () => PlayListController(),
      tag: DefaultValues.playlistControllerTag,
    );
  }
}
