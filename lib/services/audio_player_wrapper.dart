import 'dart:async';
import '../models/snapshot.dart';
import 'package:audio_service/audio_service.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import '../SettingsPage/settings_controller.dart';
import '../models/headers.dart';
import '../models/song.dart';
import 'liked_controller.dart';
import 'repositories/lyrics_repository.dart';
import 'repositories/song_repository.dart';
import 'audio_player_handler.dart';
import 'local_redirect_server.dart';
import '../models/lyrics.dart';

/// 顶层包装层:把 [AudioPlayerHandler] 的 audio_service 事件流翻译成
/// [PlaybackSnapshot] 给 UI 订阅,并把 UI 命令转发到底层。
///
/// 唯一可变状态是 [snapshot],由 5 路聚合:handler.playbackState(isPlaying /
/// processingState / position / bufferedPosition)、mediaItem(currentSong)、
/// queue、currentIndex、currentSongLiked(isCurrentSongLiked)。
class AudioPlayerService extends GetxController {
  AudioPlayerService();

  final SongRepository _songRepo = Get.find<SongRepository>();
  final LikedController _likedService = Get.find<LikedController>();
  final LyricsRepository _lyricsRepo = Get.find<LyricsRepository>();

  /// 全局音质偏好。注入给 handler 建 AudioSource 时用;wrapper 自己不读,
  /// 只持有引用避免 handler 再 Get.find。
  final SettingsController _settings = Get.find<SettingsController>();
  late final AudioPlayerHandler audioHandler;

  // ---- 业务层 Rx 集合 (跟 UI / 上层 controller 交互用) ------------------------

  /// 业务层队列(Song)。跟 [snapshot.queue](MediaItem) 由 [_onQueue] 同步。
  final RxList<Song> playlist = <Song>[].obs;

  static const _storageKey = 'playlist_v1';
  static const _currentIndexKey = 'playlist_currentIndex_v1';
  static const _modeKey = 'playlist_mode_v1';

  /// audio_service 后台播放配置。集中构造在 wrapper 而不是 main:配置是音频层
  /// 的关注点(锁屏控件 / 通知 channel / 封面降采样)。
  ///
  /// 几个非默认值的理由:
  /// - `androidStopForegroundOnPause: true` 是**强制要求** —— audio_service 的
  ///   assert 规定 ongoing=true 时 stopOnPause 必须 true,否则 debug 崩溃。
  /// - `preloadArtwork: false` 是防崩:`_loadAllArtwork` 迭代的 list 跟
  ///   QueueHandler.updateQueue 内部 `nvalue..replaceRange` 是同一份(它在 nvalue
  ///   上原地改而不是换实例),频繁 setQueue 时会 "Concurrent modification during
  ///   iteration"。封面改成显示时才下,延迟一两秒换不崩。
  /// - `artDownscaleWidth/Height: 800`:锁屏控件够清晰,避免长队列时大图 OOM。
  /// - `fastForwardInterval/rewindInterval: 15s`:比默认 10s 更符合"跳到副歌"。
  static const AudioServiceConfig _audioServiceConfig = AudioServiceConfig(
    androidNotificationChannelId: 'com.cmach.oceanus.audio',
    androidNotificationChannelName: '网易云音乐播放',
    androidNotificationChannelDescription: '后台播放与媒体控制',
    androidNotificationOngoing: true,
    androidStopForegroundOnPause: true,
    preloadArtwork: false,
    artDownscaleWidth: 800,
    artDownscaleHeight: 800,
  );

  int get headOfTheQueue => 0;
  int get tailOfTheQueue => playlist.length - 1;

  /// UI 订阅的 [currentIndex] (从 snapshot 读)。 走 wrapper 而不是 [snapshot.currentIndex]
  /// 是为了跟其他 Rx (playlist) 同步变化触发 Obx 刷新。
  RxInt get currentIndex => _currentIndexSub;
  final RxInt _currentIndexSub = (-1).obs;

  /// 播放顺序 (从 snapshot 读)
  Rx<PlayOrder> get mode => _modeRx;
  final Rx<PlayOrder> _modeRx = PlayOrder.sequential.obs;

  /// UI 唯一订阅点。任何播放相关变化都聚合到这一个 Rx。
  final Rx<PlaybackSnapshot> snapshot = Rx<PlaybackSnapshot>(
    PlaybackSnapshot(
      isPlaying: false,
      processingState: ProcessingState.idle,
      position: Duration.zero,
      bufferedPosition: Duration.zero,
      currentSong: null,
      queue: const [],
      currentIndex: -1,
      playOrder: PlayOrder.sequential,
      isCurrentSongLiked: false,
    ),
  );

  StreamSubscription<PlaybackState>? _stateSub;
  StreamSubscription<MediaItem?>? _itemSub;
  StreamSubscription<List<MediaItem>>? _queueSub;
  StreamSubscription<bool>? _currentSongLikedSub;
  StreamSubscription<PlayOrder>? _playOrderSub;

  /// handler 的 currentIndex 流订阅 (just_audio 推进 → UI 同步)
  StreamSubscription<int>? _currentIndexSub2;
  // 持久化触发器:handler.mediaItem / .queue / .playOrder 任一变化 → debounce →
  // _persist(),覆盖 wrapper 没显式包装的命令(skipToNext/自然播完/seek/setPlayOrder)
  Timer? _persistDebounce;
  // 恢复期不写盘,否则会把"刚恢复的值"再写回一遍(语义等价但浪费 IO)。
  bool _persistReady = false;

  // 不能 override onInit:GetX 的 _onStart **同步调用 onInit() 并丢弃 future**
  // (见 package:get/get_instance/src/lifecycle.dart)。onInit 里放 await 链的话,
  // handler 还没就绪 PlayerController.onInit 已经跑完,访问 wrapper.audioHandler
  // (late) 会崩。所以异步初始化挪到 [init],由 main.dart 的 `Get.putAsync` 在
  // builder 内 await —— putAsync 会 await 整链,返回时 5 路 stream 都已就绪。

  /// 启动 MediaKit + 读持久化 + 构造 handler + 订阅 5 路 stream。
  /// 只能由 main.dart 的 `Get.putAsync` builder 内 await(理由见上面)。
  Future<void> init() async {
    // 必须显式按平台 enable:默认 android/iOS/macOS 都是 false,不打开的话
    // Android 上 media_kit 后端永远不会激活,setUrl 会走 just_audio 默认 ExoPlayer
    // (网易云 CDN + ExoPlayer 首 chunk 同步 sniff 是打开 Player 冻屏的根因)。
    // 各 flag 跟 pubspec 装的 *_libs_<platform>_audio 包一一对应,删包同步删 flag,
    // 忘删会抛 Cannot find libmpv.so。
    JustAudioMediaKit.ensureInitialized(
      android: true, // dependency: media_kit_libs_android_audio
      linux: true, // dependency: media_kit_libs_linux
      windows: true, // dependency: media_kit_libs_windows_audio
    );
    // 必须放行 `ytdl` 协议,否则本机 302 server 起的地址 mpv 打不开。
    //
    // mpv 默认开着 ytdl_hook,凡是"看起来不是直链"的主机名(含 localhost)都会先
    // 丢给 yt-dlp 解析;yt-dlp 拿 `localhost` 当 YouTube 频道名去搜 → 失败 →
    // 整个源 open 失败(真机日志:`ytdl_hook: Subprocess failed: init`)。
    // `protocolWhitelist` 是 just_audio_media_kit 的静态开关,默认只到
    // http/https/file/...,不含 ytdl,这里补齐到跟 mpv 默认一致。
    // (URL 侧已用 127.0.0.1 规避,这条是双保险。)
    if (!JustAudioMediaKit.protocolWhitelist.contains('ytdl')) {
      JustAudioMediaKit.protocolWhitelist = [
        ...JustAudioMediaKit.protocolWhitelist,
        'ytdl',
      ];
    }

    // 持久化恢复:在 handler 构造前同步读 GetStorage,把真相状态(queue /
    // currentIndex / mode)作为初始值传入,避免"UI 恢复了而 handler 为空"。
    final box = GetStorage();
    final rawQueue = box.read<List>(_storageKey);
    final savedIdx = box.read<int>(_currentIndexKey) ?? -1;
    final savedMode = _decodeMode(box.read<String>(_modeKey));

    final initialItems = <MediaItem>[
      for (final e in rawQueue ?? const [])
        if (e is Map)
          Song.fromJson(Map<String, dynamic>.from(e)).toMediaItem(
            artHeaders: NeteaseImageHeaders.neteaseImageHeaders,
            // 传 Song.duration 让 _itemToSong 能还原(不然恢复后 duration 为 0,
            // 进度条 / 队列列表显示 0:00)
            duration: Duration(seconds: (e['duration'] as int?) ?? 0),
          ),
    ];
    final initialIndex = (savedIdx >= 0 && savedIdx < initialItems.length)
        ? savedIdx
        : (initialItems.isEmpty ? -1 : 0);

    audioHandler = await AudioService.init(
      builder: () => AudioPlayerHandler(
        songRepo: _songRepo,
        likedService: _likedService,
        settings: _settings,
        redirect: Get.find<LocalRedirectServer>(),
        initialQueue: initialItems,
        initialIndex: initialIndex,
        initialMode: savedMode,
      ),
      config: _audioServiceConfig,
    );
    _handlerReady = true;

    // mode 不用手动 hydrate:handler 构造时已 emit 过,下面订阅就能拿到
    // (handler 是唯一真相源,wrapper 只读不写)。

    // ---- 聚合层:5 个来源 → 1 个 Rx -----------------------------------------
    _stateSub = audioHandler.playbackState.listen(_onPlaybackState);
    _itemSub = audioHandler.mediaItem.listen(_onMediaItem);
    _queueSub = audioHandler.queue.listen(_onQueue);

    // handler 内部处理 likedSongIds 变化 + 换歌两种触发,主动 emit bool,
    // wrapper 不用自己查 _likedService
    _currentSongLikedSub = audioHandler.currentSongLiked.listen((liked) {
      snapshot.value = snapshot.value.copyWith(isCurrentSongLiked: liked);
    });
    // broadcast 无 replay,订阅后主动刷一次否则停在初始 false
    audioHandler.refreshCurrentSongLiked();

    // handler 改完 _playOrder 后主动 emit,wrapper 只读不写
    _playOrderSub = audioHandler.playOrder.listen((order) {
      _modeRx.value = order;
      _schedulePersist(); // 模式切换也要写盘
    });
    // broadcast 无 replay,兜底刷一次
    audioHandler.refreshPlayOrder();

    // snapshot.currentIndex 也由这条流写 —— 触发源相同,谁先到都不影响最终状态。
    _currentIndexSub2 = audioHandler.currentIndex.listen((idx) {
      _currentIndexSub.value = idx;
      snapshot.value = snapshot.value.copyWith(currentIndex: idx);
    });

    // 启动恢复:setAudioSources 在 handler.restore() 里(构造函数不能 await),
    // 这里 await 它 + 首项 prepare,**不含播放**,慢网不会卡住 runApp()。
    await audioHandler.restore();

    // 持久化自动触发放行:上面的 listener 都挂了 _schedulePersist(),
    // flag 保证恢复期结束才开始写盘(否则会把刚恢复的值再写回一遍)。
    _persistReady = true;
  }

  /// handler 是否已构造完成。init 失败时 [audioHandler] 仍是未赋值的 late
  /// final,退出路径不能直接摸它。
  bool _handlerReady = false;

  Future<void>? _shutdownFuture;

  /// 停播并释放 handler → just_audio → media_kit(mpv)。
  ///
  /// **必须在 app 退出之前 await**(见 `services/app_shutdown.dart` 的类注释):
  /// mpv 的 wakeup 回调是 Dart NativeCallable,engine 拆 Dart VM 后 trampoline
  /// 就失效,mpv 工作线程仍会跳过去 → SIGSEGV(退出码 139)。幂等。
  Future<void> shutdown() => _shutdownFuture ??= _shutdown();

  Future<void> _shutdown() async {
    // app 退出前把 debounce 期间未刷的状态落盘
    _persistDebounce?.cancel();
    _persistDebounce = null;
    if (_persistReady) {
      _persist();
    }
    await _stateSub?.cancel();
    await _itemSub?.cancel();
    await _queueSub?.cancel();
    await _currentSongLikedSub?.cancel();
    await _playOrderSub?.cancel();
    await _currentIndexSub2?.cancel();
    if (_handlerReady) {
      await audioHandler.dispose();
    }
  }

  @override
  void onClose() {
    unawaited(shutdown());
    super.onClose();
  }

  // ---- 聚合回调 -----------------------------------------------------------------

  void _onPlaybackState(PlaybackState s) {
    snapshot.value = snapshot.value.copyWith(
      isPlaying: s.playing,
      processingState: _toJustAudioProcessing(s.processingState),
      position: s.position,
      bufferedPosition: s.bufferedPosition,
    );
  }

  void _onMediaItem(MediaItem? item) {
    if (item == null) {
      snapshot.value = snapshot.value.copyWith(
        clearCurrentSong: true,
        currentIndex: -1,
      );
      _currentIndexSub.value = -1;
      return;
    }
    // currentIndex 走独立流(见 init 里的 _currentIndexSub2 订阅),这里只管 song
    snapshot.value = snapshot.value.copyWith(currentSong: _itemToSong(item));
    _schedulePersist();
  }

  void _onQueue(List<MediaItem> q) {
    if (Get.isLogEnable) {
      Get.log('[AudioWrapper] _onQueue len=${q.length}');
    }
    snapshot.value = snapshot.value.copyWith(queue: q);
    // 业务层同步:MediaItem 列表 → Song 列表
    playlist.assignAll(q.map(_itemToSong));
    _schedulePersist(); // 队列变化 → 写盘 (覆盖 updateQueue/setQueue/addToQueue/insertToQueue)
  }

  // ---- UI 转发到 handler ---------------------------------------------------------

  Future<void> play() => audioHandler.play();
  Future<void> pause() => audioHandler.pause();
  Future<void> stop() => audioHandler.stop();
  Future<void> seek(Duration position) => audioHandler.seek(position);
  Future<void> skipToNext() => audioHandler.skipToNext();
  Future<void> skipToPrevious() => audioHandler.skipToPrevious();
  Future<void> skipToQueueItem(int index) =>
      audioHandler.skipToQueueItem(index);

  /// 替换整个队列。`duration: s.duration` 一起传,让 _itemToSong 能还原出
  /// Song.duration(否则未播放的歌在列表里显示 0:00);真时长仍以 just_audio 的
  /// durationStream 为准。
  Future<void> setQueue(List<Song> songs, {int startIndex = 0}) {
    final items = songs
        .map(
          (s) => s.toMediaItem(
            artHeaders: NeteaseImageHeaders.neteaseImageHeaders,
            duration: s.duration,
          ),
        )
        .toList();
    return audioHandler.setQueue(items, startIndex: startIndex);
  }

  /// 切歌。
  Future<void> playSong(Song song, {List<Song>? surrounding}) async {
    if (surrounding != null && surrounding.isNotEmpty) {
      final idx = surrounding.indexWhere((s) => s.id == song.id);
      await setQueue(surrounding, startIndex: idx >= 0 ? idx : 0);
      return;
    }
    // 单曲:放进长度为 1 的队列,handler 会 fetch URL
    await setQueue([song], startIndex: 0);
  }

  /// 把歌曲 append 到队列末尾,不打断当前播放 —— 跟 `playSong`(**替换**整队列
  /// 并跳到指定歌)区分。用例:LongPressDialog "添加到播放列表"。
  Future<void> addToQueue(Song song) async {
    final item = song.toMediaItem(
      artHeaders: NeteaseImageHeaders.neteaseImageHeaders,
      duration: song.duration,
    );
    await audioHandler.addQueueItem(item);
  }

  Future<void> setPlayOrder(PlayOrder order) {
    // 纯 forward: handler 改完 _playOrder 后 emit 到 _playOrderCtrl 流,
    // wrapper 那边订阅回调自动写 _modeRx (handler 是唯一真相源)。
    // wrapper 这里不写任何 Rx — 严格单向流。
    return audioHandler.setPlayOrder(order);
  }

  /// toggle 当前歌曲的喜欢状态 (LikedType.song)
  ///
  /// 上层 (PlayerController / LyricsController 等) 想"按 like 按钮"时调
  /// 此方法, 不直接 G`et.find<LikedController>().toggle()` — 走 wrapper 集中:
  ///   - 依赖收敛: 上层 controller 只依赖 wrapper, 不需要直接 import LikedController
  ///     链路清晰: `UI → wrapper.toggleFavorite → _likedService.toggle →
  ///     likedSongIds 变化 → handler._likedSongIdsSub 监听 →
  ///     _currentSongLikedCtrl.add → wrapper snapshot.isCurrentSongLiked 更新 →
  ///     PlayerController.isLiked 镜像 → UI Obx 刷新` (整链单向流)
  ///
  /// handler 内部的 [AudioPlayerHandler.customAction] (锁屏 like 按钮) 也直接调
  /// `_likedService.toggle`, handler 是音频底层所以该处不绕 wrapper。
  Future<void> toggleFavorite(String songId) {
    return _likedService.toggle(songId, LikedType.song);
  }

  // ---- 歌词 (转发到 LyricsRepository) -----------------------------------------

  /// 拉取 songId 的歌词 (按 songId 缓存)。LyricsService 删了,走这里。
  Future<Lyrics?> fetchLyric(String songId) => _lyricsRepo.fetch(songId);

  /// 清歌词缓存 (用户手动刷新时调)。
  void invalidateLyric([String? songId]) => _lyricsRepo.invalidate(songId);

  // ---- 队列/模式业务 API (从老 PlayQueueService 迁来) -------------------------

  /// 选某一首开始播放 (UI 点队列里的某一首)
  void selectIndex(int index) {
    if (index < 0 || index >= playlist.length) return;
    // 不手动写 _currentIndexSub: handler skipToQueueItem → _playAt →
    // mediaItem.add 会回推 _onMediaItem,由它更新 (单向流,消除双写竞态)
    audioHandler.skipToQueueItem(index);
    _persist(); // 立即同步写一次 (handler 流上的 debounce 会再合并一次, 双保险)
  }

  /// 计算"下一首要播的索引"(不修改 currentIndex)
  ///
  /// 直接问 just_audio(`nextIndex` / `previousIndex` 已经把 LoopMode 的循环
  /// 语义和 shuffle 顺序算好了)。wrapper 这层**不再自己算**,避免和 handler
  /// 的播放顺序出现第二套逻辑。
  int nextIndex() => audioHandler.peekNeighbor(1);

  /// 计算"上一首要播的索引"(不修改 currentIndex)
  int prevIndex() => audioHandler.peekNeighbor(-1);

  /// 队列里删一首 (UI 调)
  void removeSong(int index) {
    if (index < headOfTheQueue || index > tailOfTheQueue) return;
    // 不写 playlist: handler 的 removeQueueItemAt 会更新 _queue 并通过
    // queue/mediaItem 流回推 _onQueue/_onMediaItem (彻底单向化)
    audioHandler.removeQueueItemAt(index);
    _persist(); // 立即同步写一次 (handler 流上的 debounce 会再合并一次, 双保险)
  }

  /// 加载多首歌作为整个队列(UI 调, 比如歌单页"播放全部")
  ///
  /// 返回 [Future<void>] 让上层 controller 可以 await (e.g.
  /// `SongListBodyController.playPlaylistById` 等首屏数据 load 完再触发)。
  Future<void> playSongs(List<Song> songs, {Song? startSong}) async {
    if (songs.isEmpty) return;
    final uniqueSongs = <Song>[];
    final seenIds = <String>{};
    for (final song in songs) {
      if (seenIds.add(song.id)) uniqueSongs.add(song);
    }
    // 不写 playlist / _currentIndexSub: 直接喂 handler, 由 queue/mediaItem
    // 流回推 _onQueue/_onMediaItem 同步 (单向流)
    final startIndex = startSong == null
        ? 0
        : uniqueSongs.indexWhere((s) => s.id == startSong.id);
    final finalStart = startIndex >= 0 ? startIndex : 0;
    await audioHandler.setQueue(
      uniqueSongs
          .map(
            (s) => s.toMediaItem(
              artHeaders: NeteaseImageHeaders.neteaseImageHeaders,
              duration: s.duration,
            ),
          )
          .toList(),
      startIndex: finalStart,
    );
    _persist();
  }

  // ---- 持久化 (从老 PlayQueueService 迁来) ------------------------------------

  /// debounce 写盘: 状态变化频繁时合并成一次磁盘 IO
  ///
  /// - 200ms 间隔足以合并 _playAt 中途的多次 mediaItem.add
  ///   (handler 内部 _playAt 大约 emit 2 次: loading → ready)
  /// - _persistReady = false 时跳过 (启动恢复期间不写盘,见 init 末尾注释)
  void _schedulePersist() {
    if (!_persistReady) return;
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 200), _persist);
  }

  void _persist() {
    if (!_handlerReady) return;
    final box = GetStorage();
    // 全部读 handler 真相: 队列 / currentIndex / mode 都从 handler 取,
    // wrapper 的 Rx 只作展示层, 不参与持久化 (彻底单向化)
    box.write(
      _storageKey,
      audioHandler.persistedQueue
          .map(_itemToSong)
          .map((s) => s.toJson())
          .toList(),
    );
    box.write(_currentIndexKey, audioHandler.persistedIndex);
    box.write(_modeKey, audioHandler.persistedMode.name);
  }

  static PlayOrder _decodeMode(String? s) {
    for (final m in PlayOrder.values) {
      if (m.name == s) return m;
    }
    return PlayOrder.sequential;
  }

  // ---- helpers -----------------------------------------------------------------

  ProcessingState _toJustAudioProcessing(AudioProcessingState s) {
    switch (s) {
      case AudioProcessingState.idle:
        return ProcessingState.idle;
      case AudioProcessingState.loading:
        return ProcessingState.loading;
      case AudioProcessingState.buffering:
        return ProcessingState.buffering;
      case AudioProcessingState.ready:
        return ProcessingState.ready;
      case AudioProcessingState.completed:
        return ProcessingState.completed;
      case AudioProcessingState.error:
        return ProcessingState.idle; // just_audio 没有 error 状态,降级
    }
  }

  /// MediaItem → Song (用于 UI 显示)
  /// MediaItem 里的 id 存的是 Song.id (String);
  /// 其他字段直接从 MediaItem.title/artist/album/artUri 翻
  Song _itemToSong(MediaItem item) {
    return Song(
      id: item.id,
      title: item.title,
      artist: item.artist ?? '',
      album: item.album ?? '',
      coverUrl: item.artUri?.toString() ?? '',
      duration: item.duration ?? Duration.zero,
    );
  }
}
