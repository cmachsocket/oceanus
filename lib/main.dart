import 'dart:io';

import 'dart:async';

import 'package:flutter/material.dart';
import 'models/Default.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';

import 'AppShell.dart';
import 'AppShellController.dart';
import 'PlayPage/LyricsController.dart';
import 'PlayPage/PlayerController.dart';
import 'SettingsPage/SettingsController.dart';
import 'services/AudioPlayerWrapper.dart';
import 'services/LyricsServerService.dart';
import 'sdk/NeteaseApi.dart';
import 'services/LikedController.dart';
import 'services/repositories/LyricsRepository.dart';
import 'services/repositories/SongRepository.dart';
import 'services/repositories/LikedRepository.dart';
import 'services/repositories/SearchRepository.dart';
import 'services/repositories/PlaylistRepository.dart';
import 'services/repositories/AlbumRepository.dart';
import 'services/repositories/ArtistRepository.dart';
import 'services/PlaylistEventsController.dart';
import 'services/repositories/LibraryRepository.dart';
import 'sdk/AuthController.dart';
import 'services/DownloadService.dart';
import 'theme/ThemeController.dart';
import 'widgets/netease_image.dart' show NeteaseHttpOverrides;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 全局 HttpClient UA 伪装:NetEase CDN 把 Dart 默认 UA 拉黑
  // (Image.network 的 headers 参数在 Android 不一定生效,直接 override 最稳)
  HttpOverrides.global = NeteaseHttpOverrides();
  await GetStorage.init();
  Get.put<ThemeController>(ThemeController(), permanent: true);
  // 网易云 SDK:启动 NcmApi (embedded node bridge) + 恢复持久化 cookie + 拉匿名 cookie。
  // 必须在 GetStorage.init 之后(读 cookie / loggedIn flag)。
  await initNeteaseApi();
  // Repositories 集中 API 调用 —— 必须在依赖它们的 service / controller 之前 put。
  // 构造注入 NeteaseApi, 注册顺序错误会编译期暴露 (README 阶段 1.1)。
  Get.put<LyricsRepository>(
    LyricsRepository(Get.find<NeteaseApi>()),
    permanent: true,
  );
  // SettingsController 必须在 SongRepository 之前: SongRepository 构造时
  // Get.find<SettingsController>() 取全局音质偏好。
  // (ThemeController 同模式, onInit 同步读 GetStorage, 不需要 putAsync)
  Get.put<SettingsController>(SettingsController(), permanent: true);
  Get.put<SongRepository>(
    SongRepository(Get.find<NeteaseApi>(), Get.find<SettingsController>()),
    permanent: true,
  );
  Get.put<SearchRepository>(
    SearchRepository(Get.find<NeteaseApi>()),
    permanent: true,
  );
  // PlaylistEventsController 必须在 PlaylistRepository 之前注册
  // (PlaylistRepository 构造时 Get.find<PlaylistEventsController>() 拿事件中心)
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
  // AuthController 是全局凭证持有者 (lib/controller/), 持有 AuthInfo (cookie + loggedIn + uid)
  // 真正的 SDK 调用走 NeteaseApi, LoginController 等 UI 层从这里拿凭证
  await Get.putAsync<AuthController>(() async {
    final controller = AuthController();
    await controller.loadAuthInfo();
    return controller;
  }, permanent: true);
  Get.put<LikedRepository>(
    LikedRepository(Get.find<NeteaseApi>()),
    permanent: true,
  );
  // 单一 LikedController: 之前 4 个 service (Songs/Albums/Artists/Playlists) 都合并到这里,
  // 按 LikedType 分桶, API 调用走 LikedRepository
  Get.put<LikedController>(LikedController(), permanent: true);

  // ---- 下载服务 (background_downloader 包装) ------------------------------
  // 依赖 SongRepository (上面已经 put 好了)。
  // Get.putAsync 是因为 init() 里有 await FileDownloader().start() 异步链,
  // 不能放进 onInit (GetX _onStart 同步调 onInit 丢 future —— 见
  // AudioPlayerService 注释里的 _onStart 引用)。putAsync 会 await builder
  // 整链, 等 start + registerCallbacks + database 反序列化都完成才返回
  // instance, 后续任何 Get.find<DownloadService>() 拿到的都是已就绪的。
  await Get.putAsync<DownloadService>(() async {
    final svc = DownloadService(Get.find<SongRepository>());
    await svc.init();
    return svc;
  }, permanent: true);

  // ---- 音频服务层 (唯一入口) -----------------------------------------------
  // NewAudioPlayerService 把"PlayQueueService + 老 AudioPlayerService +
  // PlaybackService + LyricsService"四者吸收到一个 wrapper + handler:
  //   - 业务 API: playlist / currentIndex / mode / selectIndex / setMode /
  //     playSong / playSongs / removeSong / nextIndex / prevIndex / fetchLyric /
  //     invalidateLyric
  //   - 音频命令: play / pause / seek / skipToNext / skipToPrevious
  //   - 状态聚合: Rx<PlaybackSnapshot> (isPlaying/processingState/position/
  //     bufferedPosition/currentSong/queue/currentIndex/playOrder/isCurrentSongLiked)
  //   - 后台: AudioService.init 在 wrapper.init() 里跑 (handler 内部负责
  //     audio_service + just_audio 桥接),单例 handler 暴露给锁屏/通知
  //
  // 注册顺序要求:
  //   1. Repository (SongRepository / LyricsRepository / LikedController) 在前
  //      (handler 构造依赖)
  //   2. wrapper 在 PlayerController 之前:PlayerController.onInit 会 Get.find 它
  //   3. PlayerController 在 LyricsController 之前:lyricsController 订阅 currentSong
  //   4. **用 Get.putAsync + builder 内 await wrapper.init()** —— 不能用
  //      Get.put 后再显式 await init()(留一个"已注册但未初始化"的中间态
  //      易被并发 Get.find 误用),也不能 override wrapper.onInit 放异步链
  //      (GetX 的 `_onStart` 同步调用 onInit() 并丢弃 future,见
  //      package:get/get_instance/src/lifecycle.dart _onStart)。
  //      putAsync 会 await builder() 整链,builder 内显式调 wrapper.init()
  //      等异步构造 (handler + stream 订阅) 全部就绪再返回 instance,
  //      此时 PlayerController put 进去时 wrapper.audioHandler (late) 已赋值。
  await Get.putAsync<AudioPlayerService>(() async {
    final audioWrapper = AudioPlayerService();
    await audioWrapper.init();
    return audioWrapper;
  });

  Get.put<PlayerController>(
    PlayerController(),
    tag: DefaultValues.playerControllerTag,
    permanent: true,
  );
  // LyricsController 依赖 PlayerController (订阅 currentSong) + wrapper.fetchLyric。
  // 注册顺序: wrapper → PlayerController → LyricsController。
  // **LyricsController 必须 permanent: true** — flutter_lyric 自己的 LyricController
  // 实例持有高亮行/滚动位置/已加载 lyric 等状态, 跨 PlayPage 路由切换 (push/pop
  // 后再进) 不重建才能保留这些状态; GetX 智能管理在路由 pop 时会销毁非 permanent
  // controller (LyricsController.onClose 触发 lyricController.dispose()), lyric 状态
  // 丢失。LyricsController **onInit 内的 wrapper.snapshot 订阅也会被 cancel + 重订**,
  // 重建后立刻镜像一次 wrapper.snapshot, 但 LyricController 实例换新 → 高亮位置归零。
  //
  // PlayerController 不 permanent: 重建成本低 (onInit 里 ever<PlaybackSnapshot>
  // 订阅立刻从 wrapper.snapshot 镜像一次), 跨路由切换重建不影响 Player UI
  // (Obx 读到 wrapper 实时状态), 跟 LyricsController 解耦。
  Get.put<LyricsController>(LyricsController(), permanent: true);

  // 本地 HTTP 服务 (port 41830):给外部 lyric 客户端 (YesPlayMusic 桌面端)
  // 暴露 /local-asset/player 端点。依赖 wrapper + LyricsRepository 都在上面
  // put 好了,这里异步启动(server.bind 失败 catch,端口冲突不阻断 runApp)。
  if (Platform.isLinux) {
    unawaited(_startLyricsServerSafely());
  }

  runApp(const OceanusApp());
}

Future<void> _startLyricsServerSafely() async {
  try {
    final server = Get.put<LyricsServerService>(
      LyricsServerService(),
      permanent: true,
    );
    await server.startServer();
    // ignore: avoid_print
    print('[main] LyricsServerService listening on :${server.port}');
  } catch (e, st) {
    // 端口冲突 / 权限不足 → log 但继续,UI 仍可用
    // ignore: avoid_print
    print('[main] LyricsServerService 启动失败 (端口可能占用): $e\n$st');
  }
}

class OceanusApp extends StatelessWidget {
  const OceanusApp({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Get.find<ThemeController>();
    return Obx(
      () => GetMaterialApp(
        title: 'Flutter Netease Music',
        debugShowCheckedModeBanner: false,
        initialBinding: AppShellBinding(),
        theme: theme.lightTheme,
        darkTheme: theme.darkTheme,
        themeMode: theme.mode.value,
        home: const AppShell(),
      ),
    );
  }
}
