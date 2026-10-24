import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:window_manager/window_manager.dart';

import 'app_shell.dart';
import 'app_shell_controller.dart';
import 'PlayPage/lyrics_controller.dart';
import 'PlayPage/player_controller.dart';
import 'SettingsPage/settings_controller.dart';
import 'services/audio_player_wrapper.dart';
import 'services/app_shutdown.dart';
import 'services/lyrics_server_service.dart';
import 'sdk/netease_api.dart';
import 'services/liked_controller.dart';
import 'services/repositories/lyrics_repository.dart';
import 'services/repositories/song_repository.dart';
import 'services/repositories/liked_repository.dart';
import 'services/repositories/search_repository.dart';
import 'services/repositories/playlist_repository.dart';
import 'services/repositories/album_repository.dart';
import 'services/repositories/artist_repository.dart';
import 'services/playlist_events_controller.dart';
import 'services/repositories/library_repository.dart';
import 'sdk/auth_controller.dart';
import 'services/download_service.dart';
import 'services/local_redirect_server.dart';
import 'services/tray_controller.dart';
import 'theme/theme_controller.dart';
import 'widgets/netease_image.dart' show NeteaseHttpOverrides;
import 'models/default.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 全局 HttpClient UA 伪装:Image.network 的 headers 在 Android 不一定生效
  HttpOverrides.global = NeteaseHttpOverrides();
  // 桌面平台必须在 TrayController 注册之前初始化(TrayController 靠它切窗口
  // 可见性 + macOS 拦截关闭信号)。移动端 / Web 跳过。
  if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
    await windowManager.ensureInitialized();
  }
  await GetStorage.init();
  Get.put<ThemeController>(ThemeController(), permanent: true);
  // 必须在 GetStorage.init 之后(要读 cookie / loggedIn flag)
  await initNeteaseApi();
  Get.put<LyricsRepository>(
    LyricsRepository(Get.find<NeteaseApi>()),
    permanent: true,
  );
  // SettingsController 必须在 SongRepository 之前(后者构造时 Get.find 它)
  Get.put<SettingsController>(SettingsController(), permanent: true);
  Get.put<SongRepository>(
    SongRepository(Get.find<NeteaseApi>(), Get.find<SettingsController>()),
    permanent: true,
  );
  Get.put<SearchRepository>(
    SearchRepository(Get.find<NeteaseApi>()),
    permanent: true,
  );
  // PlaylistEventsController 必须在 PlaylistRepository 之前(后者构造时 Get.find 它)
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
  // 用 putAsync 而不是 onInit:GetX 的 _onStart 同步调 onInit 并丢弃 future,
  // 里面的 await FileDownloader().start() 会被丢掉。putAsync 会 await 整链,
  // 之后任何 Get.find<DownloadService>() 拿到的都是已就绪的。
  await Get.putAsync<DownloadService>(() async {
    final svc = DownloadService(Get.find<SongRepository>());
    await svc.init();
    return svc;
  }, permanent: true);

  // ---- 本机 302 定向 server ----------------------------------------------------
  // 让 just_audio 只拿稳定地址,真地址在 prepare 那一刻才换(网易云直链只有
  // ~20min)。起不来时 enabled=false,播放链路自动退回直连。
  await Get.putAsync<LocalRedirectServer>(
    () => LocalRedirectServer(Get.find<SongRepository>()).init(),
    permanent: true,
  );

  // ---- 音频服务层 (唯一入口) -----------------------------------------------
  // 注册顺序:Repository → wrapper → PlayerController → LyricsController。
  //
  // wrapper **必须用 putAsync + builder 内 await init()**:不能用 Get.put 后再
  // 显式 await(会留一个"已注册但未初始化"的中间态,并发 Get.find 会误用),
  // 也不能 override onInit 放异步链(GetX 的 _onStart 同步调 onInit 并丢弃
  // future)。putAsync 保证返回时 handler + stream 订阅都已就绪,之后 put
  // PlayerController 时 audioHandler(already late)已赋值。
  await Get.putAsync<AudioPlayerService>(() async {
    final audioWrapper = AudioPlayerService();
    await audioWrapper.init();
    return audioWrapper;
  }, permanent: true);

  Get.put<PlayerController>(
    PlayerController(),
    tag: DefaultValues.playerControllerTag,
    permanent: true,
  );
  // LyricsController **必须 permanent**:flutter_lyric 的 LyricController 持有
  // 高亮行 / 滚动位置 / 已加载 lyric,非 permanent 会在路由 pop 时被销毁
  // (onClose → lyricController.dispose()),这些状态全丢。
  Get.put<LyricsController>(LyricsController(), permanent: true);

  // ---- 系统托盘 (桌面端) -------------------------------------------------------
  // 必须在 AudioPlayerService 注册之后:TrayController 依赖 wrapper。TrayController
  // 内部 _isSupportedPlatform 守卫,移动端 / Web 走 no-op,零开销。
  //
  // permanent: false (默认) 即可:GetX 在 app 退出时随容器一起清理,onClose 会
  // dispose TrayIcon/Menu。需要主动重置时用 Get.delete(force: true) 触发 onClose。
  if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
    Get.put<TrayController>(TrayController());
  }

  // 本地 HTTP 服务 (port 41830):给外部 lyric 客户端 (YesPlayMusic 桌面端)
  // 暴露 /local-asset/player 端点。依赖 wrapper + LyricsRepository 都在上面
  // put 好了,这里异步启动(server.bind 失败 catch,端口冲突不阻断 runApp)。
  if (Platform.isLinux) {
    unawaited(_startLyricsServerSafely());
  }

  // 退出钩子:桌面端的窗口关闭由 TrayController 拦截(见其 onWindowClose),
  // 这里兜住 macOS Cmd+Q / 桌面会话登出这类"平台请求退出"的入口。必须在拆
  // Dart VM 之前 release mpv / node / HTTP server,见 AppShutdown 类注释。
  _exitListener = AppLifecycleListener(
    onExitRequested: () async {
      await AppShutdown.run();
      return AppExitResponse.exit;
    },
  );

  runApp(const OceanusApp());
}

/// 必须持住引用,否则 [AppLifecycleListener] 会被 GC。
// ignore: unused_element
AppLifecycleListener? _exitListener;

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
