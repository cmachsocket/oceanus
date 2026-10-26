import 'package:get/get.dart';

import '../../../core/constants/default_values.dart';
import '../../playlist/controllers/play_list_controller.dart';
import '../controllers/player_controller.dart';

/// 播放页 binding。
class PlayerBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut(
      () => PlayerController(),
      tag: DefaultValues.playerControllerTag,
    );
    Get.lazyPut(
      () => PlayListController(),
      tag: DefaultValues.playlistControllerTag,
    );
  }
}
