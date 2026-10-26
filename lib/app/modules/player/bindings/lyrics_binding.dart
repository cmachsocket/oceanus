import 'package:get/get.dart';

import '../controllers/lyrics_controller.dart';

/// 歌词页 binding。
class LyricsBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<LyricsController>(() => LyricsController());
  }
}
