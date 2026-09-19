import 'dart:async';
import '../models/Snapshot.dart';
import 'package:audio_service/audio_service.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import '../SettingsPage/SettingsController.dart';
import '../models/Headers.dart';
import '../models/Song.dart';
import 'LikedController.dart';
import 'repositories/LyricsRepository.dart';
import 'repositories/SongRepository.dart';
import 'AudioPlayerHandler.dart';
import '../models/Lyrics.dart';

/// ---- 顶层包装层暴露给 UI 的快照 ------------------------------------------------

/// 播放状态快照。包装器把 [PlaybackState] + 业务上下文聚合成一份给 UI 订阅。

/// ---- 顶层包装层 ----------------------------------------------------------------
///
/// 把 [AudioPlayerHandler] 提供的 audio_service 事件流 (playbackState / mediaItem /
/// queue) 翻译成 [PlaybackSnapshot],并把 UI 命令 (play/pause/seek/skip/setQueue/
/// setPlayOrder) 转发到底层。
///
/// 唯一可变状态: [snapshot] (`Rx<PlaybackSnapshot>`),由 5 个来源聚合而成:
///   1. handler.playbackState  → isPlaying / processingState / position / bufferedPosition
///   2. handler.mediaItem       → currentSong (Song)
///   3. handler.queue           → queue
///   4. handler.currentIndex    → currentIndex
///   5. handler.currentSongLiked 流 (`Stream<bool>`) → isCurrentSongLiked
///      (handler 内部 listen likedSongIds.stream + 在 _playAt emit,
///      主动推 bool 给 wrapper,wrapper 不需要查 _likedService)
class AudioPlayerService extends GetxController {
  AudioPlayerService();

  final SongRepository _songRepo = Get.find<SongRepository>();
  final LikedController _likedService = Get.find<LikedController>();
  final LyricsRepository _lyricsRepo = Get.find<LyricsRepository>();

  /// 全局音质偏好 (SettingsPage 用户选择) —— 注入到 handler,handler 在
  /// _playAt 拉 URL 时取当前 quality 作为 level 参数。
  /// wrapper 不在这里读 currentQuality —— 单向流: handler 自己取,
  /// wrapper 只持有引用避免 handler 重新 Get.find。
  final SettingsController _settings = Get.find<SettingsController>();
  late final AudioPlayerHandler audioHandler;

  // ---- 业务层 Rx 集合 (跟 UI / 上层 controller 交互用) ------------------------

  /// 业务层队列 (Song 列表) — 与 handler 内部 [_queue] (MediaItem) 对应,
  /// 由 [_onQueue] / [setQueue] 双向同步。UI / controller 走 [playlist] 拿 Song,
  /// handler 走 [snapshot.queue] (MediaItem) 走 audio_service。
  final RxList<Song> playlist = <Song>[].obs;

  // 持久化 (从老的 PlayQueueService 迁来)
  static const _storageKey = 'playlist_v1';
  static const _currentIndexKey = 'playlist_currentIndex_v1';
  static const _modeKey = 'playlist_mode_v1';

  /// audio_service 后台播放配置
  ///
  /// 在 wrapper 这里集中构造, 不放在 main.dart — 配置是音频层的关注点
  /// (锁屏控件 / 通知 channel / 封面降采样), 不该让 app 启动入口知道细节。
  ///
  /// 各字段选择:
  ///   - `androidNotificationChannelId/Name/Description`: 通知 channel,
  ///     用户在系统设置里能看到 ("网易云音乐播放 / 后台播放与媒体控制")
  ///   - `androidNotificationOngoing: true`: 通知不可被滑掉 (音乐 app
  ///     标准 — 用户误滑不会停歌)
  ///   - `androidStopForegroundOnPause: true`: 暂停时退出 foreground service。
  ///     **强制要求** (audio_service 的 assert: ongoing=true 时 stopOnPause
  ///     必须 true, 否则 debug 崩溃)
  ///   - `androidResumeOnClick: true` (默认): 点通知恢复播放
  ///   - `preloadArtwork: false` (原本是 true): 加入队列时 audio_service 后台
  ///     isolate 会启动 `_loadAllArtwork` 异步下载所有歌的封面, 但它迭代的
  ///     list 跟 QueueHandler.updateQueue 内部 `nvalue..replaceRange` 是同一份
  ///     (audio_service 0.18.19 QueueHandler.updateQueue.dart:3323 在 nvalue 上
  ///     原地修改而不是换 nvalue 实例) —— 频繁 setQueue 时下次 iteration 期间
  ///     上次迭代还没跑完, nvalue 被原地改 → "Concurrent modification during
  ///     iteration" unhandled exception。锁屏/通知封面只在显示时才下载, 延迟
  ///     一两秒换来不崩, 划算。
  ///   - `artDownscaleWidth/Height: 800`: 网易云封面动辄 1000+px, 锁屏控件
  ///     用 800x800 已经够清晰, 避免大图 OOM (尤其播放队列长时)
  ///   - `fastForwardInterval/rewindInterval: 15s`: 锁屏快进/快退步长。
  ///     比 audio_service 默认的 10s 略大, 更符合"跳到副歌"的使用习惯
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
  // 持久化触发器: handler.mediaItem / .queue / .playOrder 任一变化 → debounce → _persist()
  // 覆盖 wrapper 没显式包装的命令 (skipToNext/Previous/自然播完/seek/setPlayOrder)
  Timer? _persistDebounce;
  // 启动恢复期间不写盘: init() 末尾的 skipToQueueItem+pause 会触发 mediaItem/queue 流,
  // 这时若挂上 persist listener 会把"刚恢复的值"再写回磁盘,虽然语义上等价但属于浪费 IO。
  bool _persistReady = false;

  // 不 override onInit: GetX 的 _onStart 同步调用 onInit() 并丢弃 future
  // (见 package:get/get_instance/src/lifecycle.dart _onStart):
  //   void _onStart() {
  //     if (_initialized) return;
  //     onInit();           // 同步调用,future 被丢弃
  //     _initialized = true;
  //   }
  // 所以 onInit 不能放 await 链 (AudioService.init / handler 异步构造等),
  // 否则 handler 还没就绪 PlayerController.onInit 已经跑完, 会出现
  // wrapper.audioHandler (late) 还未赋值就被访问的崩溃。
  //
  // 异步初始化挪到下面的 [init] 方法, 由 main.dart 用 `Get.putAsync` 在
  // builder 内 `await wrapper.init()` (跟 AuthController 同模式)。
  // putAsync 会 await builder() 整链, 等 handler + 5 路 stream 就绪
  // 再返回 instance, 之后 put PlayerController / LyricsController 时
  // wrapper.audioHandler (late) 已赋值。

  /// 异步初始化: 启动 MediaKit + 读持久化 + 构造 handler + 订阅 5 路 stream
  ///
  /// **必须由 main.dart 通过 `Get.putAsync` builder 内 `await init()` 调用**,
  /// 不能 override `onInit`(GetX 同步调用 + 丢 future), 也不能 `Get.put`
  /// 后再 await init() (留"已注册未初始化"中间态, 后续 Get.find 会拿到
  /// 未就绪的 wrapper)。见上面注释里 `_onStart` 的引用。
  Future<void> init() async {
    // MediaKit init 是同步阻塞,在 init() 里完成。
    // 后续 setUrl/play 直接用,不需要再 await ready(竞态源)。
    //
    // 显式按平台 enable: pubspec 装齐了 android/linux/windows lib 包,
    // 但默认 android/iOS/macOS 是 false。如果不显式打开,Android 上
    // media_kit 后端永远不会被激活,setUrl 走 just_audio 默认 ExoPlayer
    // (网易云 CDN + ExoPlayer 首 chunk 同步 sniff 是打开 Player 冻屏的根因)。
    // 各平台 flag 跟 pubspec 装的 *_libs_<platform>_audio 包一一对应,
    // 删包同步删 flag (忘删会抛 Cannot find libmpv.so)。
    JustAudioMediaKit.ensureInitialized(
      android: true, // dependency: media_kit_libs_android_audio
      linux: true, // dependency: media_kit_libs_linux
      windows: true, // dependency: media_kit_libs_windows_audio
    );

    // ---- 持久化恢复: 在 handler 构造前同步读 GetStorage, 把真相状态
    // (queue / currentIndex / mode) 作为 handler 的初始值传入。
    // handler 用 BehaviorSubject 在构造时 emit, wrapper 订阅后自动回放,
    // 不再由 wrapper 的 Rx 手动 hydrate (避免 UI 恢复了而 handler 为空)。
    final box = GetStorage();
    final rawQueue = box.read<List>(_storageKey);
    final savedIdx = box.read<int>(_currentIndexKey) ?? -1;
    final savedMode = _decodeMode(box.read<String>(_modeKey));

    final initialItems = <MediaItem>[
      for (final e in rawQueue ?? const [])
        if (e is Map)
          Song.fromJson(Map<String, dynamic>.from(e)).toMediaItem(
            artHeaders: NeteaseImageHeaders.neteaseImageHeaders,
            // 传 Song.duration → MediaItem.duration → wrapper._itemToSong 时
            // 还能正确还原 Song.duration (不然恢复后 playlist[i].duration == 0,
            // UI 进度条 / 队列列表显示 0:00)
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
        initialQueue: initialItems,
        initialIndex: initialIndex,
        initialMode: savedMode,
      ),
      config: _audioServiceConfig,
    );

    // mode 不需要在 wrapper 这里手动 hydrate: handler 构造时已经把
    // initialMode 写进 _playOrder 字段,并在构造尾部 emit 一次到
    // _playOrderCtrl 流, 下面订阅就会拿到 → _modeRx 自动同步。
    // (handler 是 mode 唯一真相源, wrapper 只读不写, 单向流)

    // ---- 聚合层:5 个来源 → 1 个 Rx -----------------------------------------
    _stateSub = audioHandler.playbackState.listen(_onPlaybackState);
    _itemSub = audioHandler.mediaItem.listen(_onMediaItem);
    _queueSub = audioHandler.queue.listen(_onQueue);

    // 订阅 handler 推的 currentSongLiked 流 → snapshot.isCurrentSongLiked
    // (handler 内部处理 likedSongIds 变化 + 换歌两种触发, 主动 emit bool,
    // 不用 wrapper 自己查 _likedService.likedSongIds)
    _currentSongLikedSub = audioHandler.currentSongLiked.listen((liked) {
      snapshot.value = snapshot.value.copyWith(isCurrentSongLiked: liked);
    });
    // broadcast 无 replay: 订阅后主动刷一次,避免订阅前 handler 已 emit 过
    // 导致 wrapper 的 isCurrentSongLiked 停在初始 false
    audioHandler.refreshCurrentSongLiked();

    // 订阅 handler 推的 playOrder 流 → _modeRx (handler 内部改 _playOrder
    // 后主动 emit, wrapper 只读不写, 单向流)
    _playOrderSub = audioHandler.playOrder.listen((order) {
      _modeRx.value = order;
      _schedulePersist(); // 模式切换也要写盘 (之前 setPlayOrder 漏掉了)
    });
    // broadcast 无 replay: 兜底刷一次 (handler 构造时已 emit 初始值, 但
    // 如果 init() 跑在 handler 构造**之前** (本次不会,但兜底), 订阅就会
    // 漏掉初始 emit)
    audioHandler.refreshPlayOrder();

    // ---- 启动恢复: 触发 _playAt → fetch URL → setUrl -----------------------
    // 之前 handler 只接了 initialQueue/initialIndex, 从不调 _playAt,
    // 所以 just_audio 从未 setUrl, 用户点播放时 _audio.play() 是 no-op (没 source)
    // 这里 skipToQueueItem 走 handler override (行 274) → _playAt(index),
    // 会 fetch URL + setUrl + 把 currentIndex 写进 MediaItem.extras。
    // 紧跟一个 pause() 保持"已恢复但不自动出声", 等用户点播放才 resume。
    // (后续如果想恢复 wasPlaying 状态, 改成持久化 + 读 bool 即可,
    //  本次先解决"点了没反应"这个最低优先级问题)
    if (initialIndex >= 0 && initialItems.isNotEmpty) {
      // 启动恢复: 触发 _playAt → fetch URL → setUrl -----------------------
      // 之前 handler 只接了 initialQueue/initialIndex, 从不调 _playAt,
      // 所以 just_audio 从未 setUrl, 用户点播放时 _audio.play() 是 no-op (没 source)
      // 这里 skipToQueueItem 走 handler override (行 274) → _playAt(index),
      // 会 fetch URL + setUrl + 把 currentIndex 写进 MediaItem.extras。
      // 紧跟一个 pause() 保持"已恢复但不自动出声", 等用户点播放才 resume。
      //
      // **不在这里 await**: fetchSongUrl 是同步 HTTP 请求 (走 music.163.com),
      // 在 Android 上 median 100-500ms, 移动网络/Wi-Fi 不稳时可能 1-3s,
      // 且 Get.putAsync 会 await builder() 整链, 这一 await 会阻塞 runApp(),
      // 用户看到闪屏一直卡住 (但 audio 已在播: media_kit 后端在 background
      // isolate 上跑 setUrl, 跟主 isolate 等待是独立的)。
      // 改成 fire-and-forget: AudioService.init 已经返回, 音频层可用,
      // 可以后台恢复,UI 立刻渲染,不阻塞冷启动。
      // ignore: discarded_futures
      audioHandler
          .skipToQueueItem(initialIndex)
          .then((_) => audioHandler.pause());
    }

    // ---- 持久化自动触发已就绪 ----
    // init() 上半段 (行 187-209) 已经在 _onMediaItem / _onQueue / playOrder
    // listener 内部追加了 _schedulePersist() 调用,覆盖所有状态变化路径:
    //   - skipToNext/Previous → handler 内部 _playAt → mediaItem.add
    //   - 自然播完推进      → playerStateStream.completed → _playAt → mediaItem.add
    //   - skipToQueueItem   → 同上
    //   - setPlayOrder      → handler 内部 _playOrder = ... → playOrder.add
    //   - setQueue/updateQueue → queue.add
    // 设置 flag 让 listener 在恢复期结束后开始写盘 (避免 init() 末尾的
    // skipToQueueItem+pause 触发的 emit 把"刚恢复的值"再写回 —— 虽然语义
    // 上等价,但属于浪费 IO,且容易干扰调试日志)。
    _persistReady = true;
  }

  @override
  void onClose() {
    // 兜底: app 退出前最后写一次盘, 把 debounce 期间未刷的状态落盘
    // (Android 杀进程时不保证 onClose 跑, 但 iOS / 用户主动 kill / GetX
    //  路由销毁等场景能覆盖)
    _persistDebounce?.cancel();
    if (_persistReady) {
      _persist();
    }
    _stateSub?.cancel();
    _itemSub?.cancel();
    _queueSub?.cancel();
    _currentSongLikedSub?.cancel();
    _playOrderSub?.cancel();
    audioHandler.stop();
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
    final song = _itemToSong(item);
    // queueIndex 由 handler 写在 MediaItem.extras['queueIndex'] 里
    // (避免 wrapper 依赖 _onQueue 和 _onMediaItem 之间的 stream 时序)
    final idx = item.extras?['queueIndex'] as int? ?? -1;
    snapshot.value = snapshot.value.copyWith(
      currentSong: song,
      currentIndex: idx,
    );
    // 业务层 currentIndex 同步
    _currentIndexSub.value = idx;
    _schedulePersist(); // 当前索引变化 → 写盘 (覆盖 skipToNext/Previous/自然播完/skipToQueueItem/_playAt)
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

  // 注意:不再单独订阅 handler 的 currentIndex 变化。currentIndex 由 handler
  // 在 emit MediaItem 时通过 extras['queueIndex'] 一并带过来,_onMediaItem
  // 里直接读。这样设计是因为:
  //   1. mediaItem 流已经覆盖了所有 currentIndex 变化的场景 (切歌=mediaItem 变)
  //   2. 单独 addListener 会出现两个 stream 到达 wrapper 的时序不一致风险
  //   3. ValueNotifier 在 handler 不是 GetxController 时确实合规,但没必要
  //      多开一条 channel

  // ---- UI 转发到 handler ---------------------------------------------------------

  Future<void> play() => audioHandler.play();
  Future<void> pause() => audioHandler.pause();
  Future<void> stop() => audioHandler.stop();
  Future<void> seek(Duration position) => audioHandler.seek(position);
  Future<void> skipToNext() => audioHandler.skipToNext();
  Future<void> skipToPrevious() => audioHandler.skipToPrevious();
  Future<void> skipToQueueItem(int index) =>
      audioHandler.skipToQueueItem(index);

  /// 替换整个队列。传入 Song 列表,内部翻成 MediaItem 并刷新 shuffle 映射。
  ///
  /// `duration: s.duration` 一起传入 MediaItem —— wrapper._itemToSong 翻译
  /// 时会取回 Song.duration,这样 `playlist[i].duration` 在切歌前就有合理值
  /// (否则 UI 进度条 / 队列列表里非当前歌曲显示 0:00)。
  /// handler `_playAt` 后 just_audio durationStream 会 emit 真值,handler
  /// 再用 `item.copyWith(duration: dur)` 覆盖一次(更准)。
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

  /// 把歌曲 append 到当前播放队列末尾(不打断当前播放)。
  ///
  /// **跟 `playSong` 区分**:`playSong` 是**替换**整队列并跳到指定歌,
  /// `addToQueue` 是**追加**到末尾,当前正在播放的歌不动。
  ///
  /// **数据通路**:Song → MediaItem → handler.addQueueItem。
  /// handler override 后会维护 `_queue` + shuffle 索引 + emit queue stream,
  /// wrapper 这边的 `playlist` RxList 自动同步。
  ///
  /// **用例**:LongPressDialog "添加到播放列表"。
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
  /// 此方法, 不直接 Get.find<LikedController>().toggle() — 走 wrapper 集中:
  ///   - 依赖收敛: 上层 controller 只依赖 wrapper, 不需要直接 import LikedController
  ///   - 链路清晰: `UI → wrapper.toggleFavorite → _likedService.toggle →
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
  int nextIndex() {
    if (playlist.isEmpty) return -1;
    switch (mode.value) {
      case PlayOrder.sequential:
        return (_currentIndexSub.value + 1) % playlist.length;
      case PlayOrder.shuffle:
        return audioHandler.peekNeighbor(1);
      case PlayOrder.repeatOne:
        return _currentIndexSub.value;
    }
  }

  /// 计算"上一首要播的索引"(不修改 currentIndex)
  int prevIndex() {
    if (playlist.isEmpty) return -1;
    switch (mode.value) {
      case PlayOrder.sequential:
        final p = _currentIndexSub.value - 1;
        return p < headOfTheQueue ? tailOfTheQueue : p;
      case PlayOrder.shuffle:
        return audioHandler.peekNeighbor(-1);
      case PlayOrder.repeatOne:
        return _currentIndexSub.value;
    }
  }

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
