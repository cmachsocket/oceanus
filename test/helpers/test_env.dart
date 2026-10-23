// 测试用的公共脚手架。
//
// 三件事:
//   1. [initTestStorage] —— 让 GetStorage 能落盘(测试里 path_provider 没有
//      原生实现,mock 掉 channel 指向临时目录)。
//   2. [FakeNcmBridge] / [FakeNeteaseApi] —— 把真实 node bridge 换成内存实现,
//      让 repository / controller 的测试不碰网络。
//   3. [bootstrapGetX] —— 按 main.dart 的注册顺序把 GetX 依赖图搭起来,
//      只是把真 API 换成假的。

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:ncm_api_enhanced/ncm_api_enhanced.dart';
import 'package:oceanus/SettingsPage/settings_controller.dart';
import 'package:oceanus/models/snapshot.dart' show PlayOrder;
import 'package:oceanus/models/song.dart';
import 'package:oceanus/sdk/auth_controller.dart';
import 'package:oceanus/sdk/music_response.dart';
import 'package:oceanus/sdk/netease_api.dart';
import 'package:oceanus/services/audio_player_wrapper.dart';
import 'package:oceanus/services/liked_controller.dart';
import 'package:oceanus/services/playlist_events_controller.dart';
import 'package:oceanus/services/repositories/album_repository.dart';
import 'package:oceanus/services/repositories/artist_repository.dart';
import 'package:oceanus/services/repositories/library_repository.dart';
import 'package:oceanus/services/repositories/liked_repository.dart';
import 'package:oceanus/services/repositories/lyrics_repository.dart';
import 'package:oceanus/services/repositories/playlist_repository.dart';
import 'package:oceanus/services/repositories/search_repository.dart';
import 'package:oceanus/services/repositories/song_repository.dart';

/// 不做任何 IPC 的假 bridge。
///
/// [NeteaseApi] 构造时会 new 一个 [NcmApi],后者按平台挑 bridge:测试环境
/// `defaultTargetPlatform` 是 android → MobileNcmBridge → 构造函数里
/// `DynamicLibrary.open('libncm_node_bridge.so')` 直接抛。所以必须先用
/// [NcmBridgeFactory.use] 把它换掉。
class FakeNcmBridge implements NcmBridge {
  FakeNcmBridge([this.responder]);

  /// 收到调用时返回的响应;null = 返回空 body。
  final Map<String, dynamic> Function(
    String method,
    Map<String, dynamic>? params,
  )?
  responder;

  final List<({String method, Map<String, dynamic>? params})> calls = [];

  @override
  Future<void> start() async {}

  @override
  Future<void> shutdown() async {}

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    calls.add((method: method, params: params));
    final r = responder?.call(method, params);
    return r ?? <String, dynamic>{'status': 200, 'body': <String, dynamic>{}};
  }

  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
}

/// 把 [NcmBridgeFactory] 钉到 [FakeNcmBridge] 上。必须在 new [NeteaseApi] 之前调。
void installFakeBridge([FakeNcmBridge? bridge]) {
  final b = bridge ?? FakeNcmBridge();
  NcmBridgeFactory.use(() => b);
}

/// 还原 [NcmBridgeFactory] 的默认实现。
void resetBridgeFactory() => NcmBridgeFactory.reset();

/// 不碰真实音频栈的 [AudioPlayerService]。
///
/// 真 wrapper 要靠 `init()` 起 audio_service + just_audio,测试里既慢又需要
/// 原生插件。这里只覆写 UI 会用到的几个命令,并记录调用,便于断言"UI 下发了
/// 什么命令"。
///
/// [onClose] 也被覆写:真实现会 `audioHandler.dispose()`,而测试里 handler 从没
/// init 过,那个 `late final` 字段未赋值,访问即抛。
class FakeAudioPlayerService extends AudioPlayerService {
  /// 记录收到的命令,按顺序。
  final List<String> commands = <String>[];

  @override
  void selectIndex(int index) => commands.add('selectIndex:$index');

  @override
  Future<void> play() async {
    commands.add('play');
  }

  @override
  Future<void> pause() async {
    commands.add('pause');
  }

  @override
  Future<void> skipToNext() async {
    commands.add('skipToNext');
  }

  @override
  Future<void> skipToPrevious() async {
    commands.add('skipToPrevious');
  }

  @override
  Future<void> seek(Duration position) async {
    commands.add('seek:$position');
  }

  @override
  void removeSong(int index) => commands.add('removeSong:$index');

  @override
  Future<void> toggleFavorite(String songId) async {
    commands.add('toggleFavorite:$songId');
  }

  @override
  Future<void> playSongs(List<Song> songs, {Song? startSong}) async {
    commands.add('playSongs:${songs.length}:${startSong?.id ?? ''}');
  }

  @override
  Future<void> setPlayOrder(PlayOrder order) async {
    commands.add('setPlayOrder:${order.name}');
  }

  @override
  void onClose() {
    // 故意不调 super.onClose —— 见类注释。
  }
}

/// 记录调用并按 [onCall] 返回响应的假 API。
///
/// [NeteaseApi.callApi] 是所有仓库层调用的唯一入口,覆写它就能拦截整条链路。
class FakeNeteaseApi extends NeteaseApi {
  FakeNeteaseApi(this.onCall);

  /// 按 (方法名, 位置参数) 返回响应。抛异常即模拟上游 / 桥接失败。
  final Future<MusicResponse> Function(String method, List<Object?> params)
  onCall;

  /// 已发生的调用,按顺序记录。
  final List<({String method, List<Object?> params})> calls = [];

  @override
  Future<MusicResponse> callApi(String method, List<Object?> params) {
    calls.add((method: method, params: params));
    return onCall(method, params);
  }

  /// 只按方法名返回固定响应的便捷构造。
  static FakeNeteaseApi returning(Map<String, MusicResponse> byMethod) {
    return FakeNeteaseApi((method, _) async {
      final r = byMethod[method];
      if (r == null) {
        throw ApiExceptionStub.notFound(method);
      }
      return r;
    });
  }
}

/// 假 API 抛业务异常时用的占位异常类型(避免测试依赖具体 code)。
class ApiExceptionStub implements Exception {
  ApiExceptionStub.notFound(String method) : message = 'no stub for "$method"';

  final String message;

  @override
  String toString() => 'ApiExceptionStub: $message';
}

/// 造一个 HTTP 200 的响应。
MusicResponse jsonResponse(
  Map<String, dynamic> body, {
  int status = 200,
  Map<String, String> headers = const {},
}) {
  return MusicResponse(status: status, body: body, headers: headers);
}

bool _storageReady = false;

/// 初始化 GetStorage。
///
/// get_storage 走 path_provider 拿存放目录,测试环境没有原生实现 → mock 掉
/// channel 指向临时目录。重复调用只初始化一次。
Future<void> initTestStorage() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (_storageReady) return;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final dir = Directory.systemTemp.createTempSync('oceanus_test');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => dir.path);
  await GetStorage.init();
  _storageReady = true;
}

/// 清掉 GetStorage 里的全部键(不重置容器)。
///
/// get_storage 的 `getKeys<T>()` 把整个 key 集合 cast 成 T,只有不带泛型参数
/// 调用时拿到的才是可迭代的 key 集合。
void clearTestStorage() {
  final box = GetStorage();
  // 先把 key 拷出来 —— remove 会边删边改同一个 map。
  for (final key in box.getKeys().cast<String>().toList()) {
    box.remove(key);
  }
}

/// 按 main.dart 的顺序把 GetX 依赖图搭起来,真 API 换成 [api]。
///
/// [onCall] 拦截 `NeteaseApi.callApi`(仓库层走的入口)。
/// [bridge] 拦截更底层的 bridge 调用 —— `NeteaseApi` 自己的方法(登录 /
///
/// 验证码 / 游客 cookie 等)不走 `callApi`,只能从这一层拦。
///
/// 返回搭好的 [FakeNeteaseApi],方便断言调用参数。
Future<FakeNeteaseApi> bootstrapGetX({
  Future<MusicResponse> Function(String method, List<Object?> params)? onCall,
  FakeNcmBridge? bridge,
}) async {
  await initTestStorage();
  installFakeBridge(bridge);

  final api = FakeNeteaseApi(
    onCall ??
        ((method, params) async => jsonResponse(<String, dynamic>{
          'code': 200,
          'result': <String, dynamic>{},
        })),
  );

  Get.put<NeteaseApi>(api, permanent: true);
  Get.put<SettingsController>(SettingsController(), permanent: true);
  Get.put<SongRepository>(
    SongRepository(Get.find<NeteaseApi>(), Get.find<SettingsController>()),
    permanent: true,
  );
  Get.put<SearchRepository>(
    SearchRepository(Get.find<NeteaseApi>()),
    permanent: true,
  );
  Get.put<PlaylistEventsController>(
    PlaylistEventsController(),
    permanent: true,
  );
  Get.put<PlaylistRepository>(
    PlaylistRepository(Get.find<NeteaseApi>()),
    permanent: true,
  );
  Get.put<AlbumRepository>(
    AlbumRepository(Get.find<NeteaseApi>()),
    permanent: true,
  );
  Get.put<ArtistRepository>(
    ArtistRepository(Get.find<NeteaseApi>()),
    permanent: true,
  );
  Get.put<LibraryRepository>(
    LibraryRepository(Get.find<NeteaseApi>()),
    permanent: true,
  );
  Get.put<AuthController>(AuthController(), permanent: true);
  Get.put<LikedRepository>(
    LikedRepository(Get.find<NeteaseApi>()),
    permanent: true,
  );
  Get.put<LikedController>(LikedController(), permanent: true);
  Get.put<LyricsRepository>(
    LyricsRepository(Get.find<NeteaseApi>()),
    permanent: true,
  );

  return api;
}

/// 拆掉 [bootstrapGetX] 搭的依赖图。
void teardownGetX() {
  Get.deleteAll(force: true);
  resetBridgeFactory();
}
