import 'package:get/get.dart';

import '../controllers/search_controller.dart';

/// 搜索页 binding:跟 LibraryController / ArtistController 同款,由
/// [AppShell._bindingForTab] 在切到搜索 tab 时按需注入,路由 pop 时随 binding 销毁
class SearchPageBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<SearchController>(() => SearchController());
  }
}
