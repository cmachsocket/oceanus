import 'dart:async';
import '../models/Snapshot.dart';
import 'package:audio_service/audio_service.dart';
import 'package:get/get.dart';
import 'package:just_audio/just_audio.dart';

import '../SettingsPage/SettingsController.dart';
import 'LikedController.dart';
import 'LocalRedirectServer.dart';
import 'repositories/SongRepository.dart';

/// ---- 后台播放 handler (audio_service + just_audio 桥接) ------------------------
///
/// 职责:
///
///   1. 订阅 [_audio] 的原生 stream,转发给 audio_service 广播:
///        - playerStateStream       → playbackState.add()
///        - sequenceStateStream     → mediaItem / queue / currentIndex / playOrder
///        - durationStream          → mediaItem.add(更新 duration)
///        - positionStream          → playbackState.add(更新 position)
///        - bufferedPositionStream  → playbackState.add(更新 bufferedPosition)
///        - errorStream             → loadError 状态
///   2. 接收 audio_service 系统控制 (play/pause/seek/skip/customAction)
///      并翻译成 just_audio 操作
///   3. **队列 / 当前索引 / 播放顺序 / shuffle 全部由 just_audio 持有**
///      (setAudioSources + currentIndex + LoopMode + shuffleModeEnabled),
///      handler 只做翻译,不再维护自己的 [_queue] / [_currentIndex] /
///      [_playOrder] / [_shuffleOrder]
///
/// 设计原则:
///
///   - **队列只有一个真相**: [_audio] 的 audioSources。每个 AudioSource 的
///     `tag` 存对应的 [MediaItem],所以 UI 列表 / audio_service 的 queue / 持久化
///     都能从 just_audio 反查回来,不需要第二份副本去同步(旧实现里 `_queue` 和
///     just_audio 的 playlist 各存一份,是这类 bug 的根源)
///   - **不持有派生状态**: isLiked / currentSong 都不在这里存,由上层包装器从 stream 聚合
///   - **降级要显式**: 本机 302 server 起不来时不能静默丢歌,取不到地址的项会被
///     剔除并打日志
class AudioPlayerHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  AudioPlayerHandler({
    required this._songRepo,
    required this._likedService,
    required this._settings,
    required this._redirect,
    List<MediaItem> initialQueue = const [],
    int initialIndex = -1,
    PlayOrder initialMode = PlayOrder.sequential,
  }) {
    // 持久化恢复的三件套先存着 —— 构造函数不能 await,真正的
    // setAudioSources 放在 [restore] 里,由 wrapper.init() 在
    // AudioService.init 之后 await(见那里的注释)
    _initialQueue = List.of(initialQueue);
    _initialIndex = initialIndex;
    _initialMode = initialMode;

    // 初始 state: 启用 seek 系列系统手势 + 三按钮基础控件
    playbackState.add(
      playbackState.value.copyWith(
        controls: _baseControls,
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
      ),
    );

    // queue / mediaItem 是 BehaviorSubject (带当前值 replay):
    // wrapper 订阅后立即拿到初始值, 真相状态在 handler 落地
    //
    // ⚠️ **这里必须是 growable 的 `<MediaItem>[]`,不能写 `const []`**:
    // audio_service 的 QueueHandler.updateQueue 实现是
    //     queue.add(queue.nvalue!..replaceRange(0, nvalue.length, newQueue))
    // —— 它**原地修改 BehaviorSubject 缓存的 nvalue**。nvalue 就是构造时这里
    // add 进去的那个实例,一旦是 const list,后续**每一次** super.updateQueue
    // 都会抛 "Cannot remove from an unmodifiable list"(真机崩过: unhandled
    // exception 直接打断 AudioPlayerService.init 的 await 链)。
    // 老实现传的是 `_queue.toList()`(growable 副本),所以一直没踩到这个坑。
    queue.add(<MediaItem>[]);
    mediaItem.add(null);
    // playOrder 是 broadcast (无 replay): handler 构造时 emit 一次初始值,
    // wrapper 订阅后立刻拿到 (或在 onInit 里调 refreshPlayOrder 兜底)。
    // 之所以不用 BehaviorSubject 是因为 mode 只有 3 个枚举值, 没有"replay
    // 历史"语义, broadcast 更轻量。
    _playOrderCtrl.add(initialMode);

    _wireAudioStreams();
  }

  // ---- 依赖 ---------------------------------------------------------------------

  final SongRepository _songRepo;
  final LikedController _likedService;

  /// 全局音质偏好 (用户设置)。
  ///
  /// **只在降级路径直接读**:本机 302 server 开启时,音质是**请求那一刻**由
  /// server 现读的(地址里不带 `?q=`)—— 队列是一次性建好的,构建时把音质烤进
  /// 地址会导致"改了音质但队列里还是旧音质"。
  final SettingsController _settings;

  /// 本机 302 定向 server —— 把 [MediaItem] 翻译成 just_audio 的 AudioSource。
  ///
  /// 开启时队列里存的是 `http://localhost:<port>/s/<songId>/xxx` 这种稳定地址,
  /// 真地址由 server 在 prepare 那一刻解析并 302 出去 —— 网易云直链只有 ~20min
  /// 寿命,提前解析存进队列的话排到队尾必过期。
  ///
  /// server 没起来 (端口被占 / web) 时 [LocalRedirectServer.enabled] 为 false,
  /// [_buildSources] 会退回"一次性批量解析真地址"。
  final LocalRedirectServer _redirect;

  final AudioPlayer _audio = AudioPlayer();

  /// 启动恢复用的持久化快照,构造时存下、由 [restore] 消费
  List<MediaItem> _initialQueue = const [];
  int _initialIndex = -1;
  PlayOrder _initialMode = PlayOrder.sequential;

  /// 启动恢复:把持久化队列灌进 just_audio 的内置队列。
  ///
  /// **必须由 wrapper.init() await** —— 它构造 handler 时拿不到 Future,只能在
  /// 这里补。await 之后 playlist / currentIndex / loopMode 才与持久化状态一致,
  /// 上层再订阅 queue/mediaItem/playOrder 三条流。
  Future<void> restore() async {
    if (_initialQueue.isEmpty) {
      await _applyPlayOrder(_initialMode);
      await super.updateQueue(<MediaItem>[]);
      mediaItem.add(null);
      return;
    }
    final index = _initialIndex.clamp(0, _initialQueue.length - 1);
    // playWhenReady: false —— 启动只恢复队列,不自动开始播
    // (老实现是 init() 末尾 skipToQueueItem + pause)
    await _setPlaylist(_initialQueue, index, play: false);
    await _applyPlayOrder(_initialMode);
  }

  /// likedSongIds 变化的订阅 (用于锁屏 like 按钮 icon 实时更新)
  StreamSubscription<Set<String>>? _likedSongIdsSub;

  /// 当前歌曲是否被喜欢 — 推送给上层 wrapper 同步 snapshot.isCurrentSongLiked
  ///
  /// 设计: 不用 refreshIsLiked() 公开方法让上层调,handler 主动 emit bool 流,
  /// wrapper 直接订阅 ([_currentSongLiked] getter)。事件源两个:
  ///   1. likedSongIds 变化 (在 _wireAudioStreams 里 listen)
  ///   2. _currentItem 变化 (在 _playAt / removeQueueItemAt 等 emit mediaItem 时
  ///      顺手 _currentSongLiked.add(...))
  /// wrapper 拿到 bool 后,copyWith(snapshot.isCurrentSongLiked) 一行搞定
  final StreamController<bool> _currentSongLikedCtrl =
      StreamController<bool>.broadcast();

  /// 公开给 wrapper 订阅 (handler 主动 emit 当前歌的 like 状态)
  Stream<bool> get currentSongLiked => _currentSongLikedCtrl.stream;

  /// 主动刷一次当前歌的 liked 状态 (broadcast 无 replay,wrapper 订阅后兜底用)
  void refreshCurrentSongLiked() => _emitCurrentSongLiked();

  /// 播放顺序变化流 — 推送给 wrapper 同步 _playOrderSub
  ///
  /// 设计: 跟 currentSongLiked 一样,handler 只做翻译,真相在 just_audio
  /// (LoopMode + shuffleModeEnabled)。[setPlayOrder] 改完、以及原生侧自己改
  /// loopMode 时(见 [_wireAudioStreams] 第 2 段)都会 emit,wrapper 只订阅。
  final StreamController<PlayOrder> _playOrderCtrl =
      StreamController<PlayOrder>.broadcast();

  /// 公开给 wrapper 订阅 (handler 主动 emit 播放顺序)
  Stream<PlayOrder> get playOrder => _playOrderCtrl.stream;

  /// 主动刷一次当前 playOrder (broadcast 无 replay, wrapper 订阅后兜底用)
  void refreshPlayOrder() => _playOrderCtrl.add(_playOrder);

  /// 当前索引变化流 —— 给 wrapper 同步 snapshot.currentIndex / RxInt currentIndex。
  ///
  /// 老实现是 handler 把 queueIndex 写进 `MediaItem.extras['queueIndex']`,
  /// wrapper 从 mediaItem 流里反解 —— 耦合且容易和队列变动错位。现在 index
  /// 有独立出口:just_audio 的 sequenceState → handler → 这条流。
  Stream<int> get currentIndex => _currentIndexCtrl.stream;

  /// 主动刷一次当前索引 (broadcast 无 replay,启动恢复后兜底用)
  void refreshCurrentIndex() => _currentIndexCtrl.add(_currentIndex);

  final StreamController<int> _currentIndexCtrl =
      StreamController<int>.broadcast();

  // ---- sequenceState 的 diff 缓存 ------------------------------------------------
  //
  // sequenceStateStream 会为 index / sequence / loopMode / shuffleMode 的**任意**
  // 组合变化发同一个通知,靠这三个字段把"到底哪一类变了"拆出来,避免每条通知都
  // 重发 queue + mediaItem(重发会让 audio_service 通知链抖,锁屏 UI 闪)。
  List<AudioSource>? _lastSequence;
  int? _lastEmittedIndex;
  PlayOrder? _lastEmittedOrder;

  /// 释放 handler 持有的订阅 (handler dispose 时由 audio_service 框架调用)
  void dispose() {
    _likedSongIdsSub?.cancel();
    _likedSongIdsSub = null;
    _currentSongLikedCtrl.close();
    _playOrderCtrl.close();
    _currentIndexCtrl.close();
  }

  // ---- 队列快照 (全部从 just_audio 反查,不再自己存) -----------------------------

  /// 队列快照:MediaItem 存在每个 AudioSource 的 `tag` 里。
  ///
  /// 老实现这里是一份独立的 `_queue` 字段,跟 just_audio 的 playlist 各存一份,
  /// 任何一处漏更新就会出现"UI 列表和实际播放不一致"。现在只有一份。
  List<MediaItem> get _items => _audio.audioSources
      .whereType<IndexedAudioSource>()
      .map((s) => s.tag)
      .whereType<MediaItem>()
      .toList();

  /// 当前播放项在 [_items] 里的下标;没有就 -1。
  int get _currentIndex => _audio.currentIndex ?? -1;

  /// 当前播放的 MediaItem（== _items[_currentIndex]，带边界保护）。
  MediaItem? get _currentItem {
    final i = _currentIndex;
    final items = _items;
    return (i >= 0 && i < items.length) ? items[i] : null;
  }

  /// 当前播放顺序 —— 从 just_audio 的 LoopMode + shuffleModeEnabled 反推。
  PlayOrder get _playOrder {
    if (_audio.loopMode == LoopMode.one) return PlayOrder.repeatOne;
    return _audio.shuffleModeEnabled ? PlayOrder.shuffle : PlayOrder.sequential;
  }

  /// 只读暴露给 wrapper 的 _persist 用 (避开 Rx 异步滞后的旧值)。
  int get persistedIndex => _currentIndex;
  PlayOrder get persistedMode => _playOrder;
  List<MediaItem> get persistedQueue => List.unmodifiable(_items);
  // 注:currentIndex 不再从 MediaItem.extras 里读。老实现把 queueIndex 塞进
  // extras 再让 wrapper 反解,是因为 handler 当时没有 index 的出口;现在直接
  // 用 [currentIndex] 这条流(wrapper 订阅),extras 不再承担传输职责。

  // ---- 订阅接线 (在构造里跑一次) -------------------------------------------------

  void _wireAudioStreams() {
    // 1. 播放状态 → playbackState
    //
    // **不再在这里做"播完自动下一首"**:老实现因为是 setUrl 单曲驱动
    // (just_audio 没有 playlist,currentIndex 永远是 0),必须手动监听
    // completed → _neighbor(1) → _playAt(next)。现在队列交给
    // setAudioSources,**自动推进是 just_audio / 原生后端(mpv / ExoPlayer)
    // 自己的事**:加载到下一首、currentIndexStream 推进、processingState
    // 重新进 loading。completed 只在整个队列走完(或 LoopMode 不是 all/one
    // 且到末尾)时才出现 —— 这里保留原样映射即可。
    _audio.playerStateStream.listen((state) {
      // liked 状态查 _likedService.isLiked (实时查,不缓存);
      // 这里在 playerStateStream 顺带把 controls 同步上 (因为 controls 含 playing
      // 状态,play 状态变化时也要 rebuild,此时再带一次最新 liked)
      final liked = _likedService.isLiked(
        _currentItem?.id ?? '',
        LikedType.song,
      );
      playbackState.add(
        playbackState.value.copyWith(
          playing: state.playing,
          processingState: _mapProcessingState(state.processingState),
          controls: _buildControls(isCurrentSongLiked: liked),
          speed: 1.0,
        ),
      );
    });

    // 2. sequenceState → queue / mediaItem / currentIndex / playOrder
    //
    // just_audio 的 sequenceStateStream 是**唯一**需要听的流:currentIndexStream
    // / sequence / shuffleIndices / loopMode / shuffleModeEnabled 全都是它的
    // 派生流(见 just_audio 内部 addStream 接线),所以只听一条就不会漏事件、
    // 也不会两条流到达顺序打架。
    //
    // 四类变化在这里统一 fan-out 给 audio_service:
    //   - currentIndex 变 → mediaItem + currentIndex 流 + liked 状态
    //   - sequence 变(增删改队列)→ queue
    //   - loopMode / shuffleModeEnabled 变 → playOrder(原生侧改的也要同步)
    _audio.sequenceStateStream.listen((seq) {
      final seqChanged =
          !identical(_lastSequence, seq.sequence) ||
          _lastSequence?.length != seq.sequence.length;
      _lastSequence = seq.sequence;
      final indexChanged = _lastEmittedIndex != seq.currentIndex;
      _lastEmittedIndex = seq.currentIndex;

      if (seqChanged) {
        // **必须传 _items.toList() 而不是 _items 本身**:
        // audio_service 的 QueueHandler.updateQueue 内部会对传进来的 list 做
        // replaceRange 原地修改(播完自动 advance 时插入下一项),并把它缓存进
        // BehaviorSubject 的 nvalue。_items 每次都是一个新 list,直接传虽然当下
        // 可变,但缓存进去的那个实例会被 audio_service 后续再用;只要**同一个实例**
        // 第二次进 updateQueue,它已经被上一次调用改成 unmodifiable 了,于是抛
        // "Cannot remove from an unmodifiable list"。
        // 所以每次都交一份全新的可变副本(跟老实现 `_queue.toList()` 同理)。
        super.updateQueue(_items.toList());
      }
      if (indexChanged || seqChanged) {
        mediaItem.add(_currentItem);
        _currentIndexCtrl.add(_currentIndex);
        // 切歌后 liked 状态会停留在上一首,这里重新推一次
        _emitCurrentSongLiked();
      }
      if (_lastEmittedOrder != _playOrder) {
        _lastEmittedOrder = _playOrder;
        _playOrderCtrl.add(_playOrder);
      }
    });

    // 3. 时长变化 → 更新当前 MediaItem 的 duration
    //
    // tag 里的 MediaItem 是不可变的快照,改不了;这里只把带真时长的这份
    // 发给 audio_service(锁屏进度条 + UI 显示用)。队列里其他歌仍用
    // Song.toMediaItem 时带的 duration,切到那首时它才被真值覆盖。
    _audio.durationStream.listen((dur) {
      if (dur == null) return;
      final item = _currentItem;
      if (item == null) return;
      if (item.duration == dur) return; // 没变就别 add (避免无效广播)
      mediaItem.add(item.copyWith(duration: dur));
    });

    // 4. 位置流 → playbackState (audio_service 锁屏进度条需要)
    _audio.positionStream.listen((pos) {
      playbackState.add(playbackState.value.copyWith(updatePosition: pos));
    });

    // 5. 缓冲位置
    _audio.bufferedPositionStream.listen((buf) {
      playbackState.add(playbackState.value.copyWith(bufferedPosition: buf));
    });

    // 6. 加载错误 → 统一的失败路径
    //
    // 为什么这是唯一的失败来源:地址解析搬到了本机 302 server,`setAudioSources`
    // 只会拿到 `http://localhost:<port>/s/<songId>/xxx` 这种必然"可达"的地址 ——
    // 取不到真地址(404)、CDN 拒绝(403)、超时,全都表现为播放器的**异步**报错。
    // 老实现的 fail-fast(`fetchSongUrl` 返回 null 就提前 return)随队列改造一起没了。
    _audio.errorStream.listen((e) {
      if (_currentIndex < 0) return;
      _emitLoadError('load failed: ${e.message} (${e.code})');
    });

    // 7. likedSongIds 变化 → emit isCurrentSongLiked 给 wrapper 订阅,
    //    同时重建 controls (锁屏 like 按钮 icon/label 实时更新)
    //
    // RxSet.stream 返回 Stream<Set<String>>,可以直接 .listen
    // (跟 RxInt.stream、RxString.stream 一样的 API,
    // 文档: https://pub.dev/documentation/get/latest)
    _likedSongIdsSub = _likedService.likedSongIds.stream.listen((_) {
      _emitCurrentSongLiked();
    });
  }

  /// 查当前歌的 like 状态 → emit 给 wrapper + 重建 controls
  ///
  /// 由 (a) likedSongIds 变化 (b) _currentItem 变化 触发。
  void _emitCurrentSongLiked() {
    final cur = _currentItem;
    final liked = cur != null && _likedService.isLiked(cur.id, LikedType.song);
    // 推 wrapper
    _currentSongLikedCtrl.add(liked);
    // 重建锁屏 controls
    playbackState.add(
      playbackState.value.copyWith(
        controls: _buildControls(isCurrentSongLiked: liked),
      ),
    );
  }

  // ---- BaseAudioHandler API override ---------------------------------------------

  /// 替换整个队列,并从 [startIndex] 开始播。
  ///
  /// 走 just_audio 的 `setAudioSources` —— 队列 / 索引 / shuffle 全部交给它,
  /// 本方法只负责把 MediaItem 翻译成 AudioSource(见 [_buildSources])。
  ///
  /// 注意 [startIndex] 会被 clamp;降级路径下(取不到真地址的项被剔除)也会跟着
  /// 左移,保证"要播的还是同一首"。
  Future<void> setQueue(List<MediaItem> newQueue, {int startIndex = 0}) async {
    if (newQueue.isEmpty) {
      await _audio.stop();
      await _audio.clearAudioSources();
      mediaItem.add(null);
      await super.updateQueue(<MediaItem>[]);
      return;
    }
    final (sources, index) = await _buildSources(newQueue, startIndex);
    if (sources.isEmpty) {
      // 一首都取不到地址(VIP / 地区限制 / 未登录):不要把队列清空后无声,
      // 显式报错让上层知道
      await _audio.stop();
      mediaItem.add(null);
      await super.updateQueue(<MediaItem>[]);
      playbackState.add(
        playbackState.value.copyWith(
          playing: false,
          processingState: AudioProcessingState.idle,
          errorCode: 0,
          errorMessage: '这些歌都取不到播放地址(VIP / 地区限制 / 未登录?)',
        ),
      );
      return;
    }
    await _audio.setAudioSources(sources, initialIndex: index);
    // just_audio 0.10 的 setAudioSources 不会自动出声,必须显式 play()
    // (老实现里是 _playAt 末尾的 `await _audio.play()`)
    await _audio.play();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    final items = _items;
    if (index < 0 || index >= items.length) return;
    // 从 0 开始播这一首(不沿用上一首的 position),语义跟老实现 _playAt 一样
    await _audio.seek(Duration.zero, index: index);
    if (!_audio.playing) await _audio.play();
  }

  @override
  Future<void> skipToNext() async {
    if (_audio.nextIndex == null) return;
    await _audio.seekToNext();
    if (!_audio.playing) await _audio.play();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_audio.previousIndex == null) return;
    await _audio.seekToPrevious();
    if (!_audio.playing) await _audio.play();
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    final items = _items;
    if (index < 0 || index >= items.length) return;
    final wasCurrent = index == _currentIndex;

    // just_audio 内部会同步维护 shuffle 顺序(ConcatenatingAudioSource.removeAt
    // 调 _shuffleOrder.removeRange),所以"删歌不重洗"这个语义不用我们再实现了
    await _audio.removeAudioSourceAt(index);

    if (_audio.audioSources.isEmpty) {
      mediaItem.add(null);
      await super.updateQueue(<MediaItem>[]);
      return;
    }
    if (wasCurrent) {
      // 删掉的是当前这首:保留老语义 —— 从队列第一首重新播
      await _audio.seek(Duration.zero, index: 0);
      if (!_audio.playing) await _audio.play();
    }
    // 其余情况 (删的不是当前 / 队列还有歌):just_audio 自己会重排索引并推进,
    // sequenceStateStream 触发 → _wireAudioStreams 里推 queue / mediaItem /
    // currentIndex,不需要在这里手动 emit
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    // 系统/外部调用 (锁屏 widget 拖队列等) 会走这里
    // 我们信任 caller,直接接管,并尽量停在原来那首
    final idx = _currentIndex;
    await setQueue(
      queue,
      startIndex: (idx >= 0 && idx < queue.length) ? idx : 0,
    );
  }

  /// 单曲 append 到队列末尾(不打断当前播放)。
  ///
  /// **不调 seek/播放**:addQueueItem 的语义是"队列加一首",不是"跳到这首"
  /// —— 跟 [skipToQueueItem] 区分清楚。
  ///
  /// just_audio 的 `addAudioSource` 会把新项插进当前 shuffle 顺序的末尾,
  /// queue / mediaItem 由 sequenceStateStream 自动推给 wrapper。
  @override
  Future<void> addQueueItem(MediaItem item) async {
    final (source, _) = await _buildSources([item], 0);
    if (source.isEmpty) return;
    await _audio.addAudioSource(source.first);
  }

  // ---- just_audio 桥接 ----------------------------------------------------------

  @override
  Future<void> prepareFromUri(Uri uri, [Map<String, dynamic>? extras]) async {
    // **不经过本机 302 server**:这个入口的 uri 是平台侧给的外部地址
    // (Android Auto / 系统媒体会话),不是我们队列里的 songId token,
    // server 也解不出东西来。要拦它只能拦它自己(目前没有调用方)。
    await _audio.setUrl(uri.toString());
  }

  @override
  Future<void> play() => _audio.play();

  @override
  Future<void> pause() => _audio.pause();

  @override
  Future<void> stop() async {
    await _audio.stop();
  }

  @override
  Future<void> seek(Duration position) => _audio.seek(position);

  /// 锁屏 like 按钮 → 转发到 LikedController.toggle (LikedType.song) (由 service 自己做乐观更新 + 错误提示)
  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    if (name != 'toggleLike') return null;
    final cur = _currentItem;
    if (cur == null) return null;
    // LikedController.toggle 接收 (id, LikedType),内部会触发 likedSongIds 变化,
    // handler 内部 listen likedSongIds.stream → _emitCurrentSongLiked →
    // 自动重建 controls + 推 currentSongLiked 给 wrapper。
    await _likedService.toggle(cur.id, LikedType.song);
    return null;
  }

  // (refreshIsLiked 已删 — 现在通过 currentSongLiked stream 推送给 wrapper,
  //  上层不需要再调一个公开方法;liked 变化全在 handler 内部处理)

  // ---- 播放顺序控制 -------------------------------------------------------------

  Future<void> setPlayOrder(PlayOrder order) async {
    if (_playOrder == order) return;
    await _applyPlayOrder(order);
    _playOrderCtrl.add(_playOrder);
  }

  /// PlayOrder → just_audio 的 LoopMode + shuffleModeEnabled。
  ///
  /// 映射表(不是随手写的,是对着老实现的语义反推的):
  /// | PlayOrder    | LoopMode | shuffle |
  /// |--------------|----------|---------|
  /// | sequential   | all      | false   |
  /// | shuffle      | all      | true    |
  /// | repeatOne    | one      | false   |
  ///
  /// **sequential 为什么是 all 而不是 off**:老实现的 `_neighbor` 在 sequential 下
  /// 是 `(_currentIndex ± 1 + n) % n`,也就是**头尾循环**(列表循环,网易云/QQ 音乐
  /// 的默认行为)。映射成 LoopMode.off 会变成"播完最后一首就停" —— 那是行为变更。
  /// just_audio 的 `_getRelativeIndex` 在 LoopMode.all 下越界才做 `% n`,正好对上。
  ///
  /// repeatOne 下 just_audio 的 `nextIndex == currentIndex`,所以
  /// [skipToNext] 在单曲循环里会重播本曲 —— 这跟老实现一致(不是这里引入的),
  /// 如果要改成"永远跳下一首",需要在 skipToNext 里特判。
  Future<void> _applyPlayOrder(PlayOrder order) async {
    await _audio.setLoopMode(
      order == PlayOrder.repeatOne ? LoopMode.one : LoopMode.all,
    );
    final shuffle = order == PlayOrder.shuffle;
    if (_audio.shuffleModeEnabled != shuffle) {
      // 打开 shuffle 会重洗一次(老实现切模式时也是重新 shuffle),
      // 关掉则回到自然顺序。删歌时的"稳定删除"由 just_audio 自己维护,
      // 不需要我们再维护映射表。
      await _audio.setShuffleModeEnabled(shuffle);
    }
  }

  // ---- 内部:MediaItem → AudioSource --------------------------------------------

  /// 把 [items] 灌成 just_audio 的内置队列,并从 [startIndex] 开始。
  ///
  /// [play] 决定灌完要不要出声。just_audio 0.10 的 `setAudioSources` 没有
  /// `playWhenReady` 参数(那是 0.7 以前的写法),要自动播必须显式 `play()` ——
  /// 所以这里手动补,别以为 setAudioSources 会自己开始播。
  ///
  /// queue / mediaItem / currentIndex 不在这里手工 emit —— `setAudioSources`
  /// 会触发 sequenceStateStream,由 [_wireAudioStreams] 统一 fan-out。
  Future<void> _setPlaylist(
    List<MediaItem> items,
    int startIndex, {
    bool play = true,
  }) async {
    final (sources, index) = await _buildSources(items, startIndex);
    if (sources.isEmpty) {
      await _audio.stop();
      await _audio.clearAudioSources();
      mediaItem.add(null);
      await super.updateQueue(<MediaItem>[]);
      return;
    }
    await _audio.setAudioSources(sources, initialIndex: index);
    if (play) await _audio.play();
  }

  /// 把 MediaItem 列表翻成 just_audio 的 AudioSource 列表。
  ///
  /// 两条路(见 [LocalRedirectServer]):
  /// - **server 开启**:每首歌只生成一个稳定地址,**零网络请求**;真地址在
  ///   播放器 prepare 那一刻由 server 现查 + 302。
  ///   注意地址里**不带音质**:队列是一次性建好的,音质要是烤进地址,用户在
  ///   播放中途改音质就不会生效(老实现是每次切歌现读 `_settings`)。
  /// - **降级**(端口被占 / web 不支持 dart:io):只能一次性把真地址全解析出来,
  ///   用 `/song/url/v1` 的批量参数一次问完(而不是 N 首歌 N 次请求)。
  ///   取不到地址的项(VIP / 地区限制 / 未登录)**直接剔除**,并把 [startIndex]
  ///   按剔除数量左移,保证要播的还是同一首。
  ///
  /// 返回 `(sources, 调整后的 startIndex)`。
  Future<(List<AudioSource>, int)> _buildSources(
    List<MediaItem> items,
    int startIndex,
  ) async {
    if (_redirect.enabled) {
      return (
        [
          for (final item in items)
            ProgressiveAudioSource(
              _redirect.urlFor(
                songId: item.id,
                quality: _settings.currentQuality.value.name,
              ),
              tag: item,
            ),
        ],
        startIndex,
      );
    }

    final urls = await _songRepo.fetchSongUrls(
      items.map((e) => e.id).toList(),
      level: _settings.currentQuality.value.name,
    );
    final sources = <AudioSource>[];
    var droppedBeforeStart = 0;
    for (var i = 0; i < items.length; i++) {
      final url = urls[items[i].id];
      if (url == null || url.isEmpty) {
        if (i < startIndex) droppedBeforeStart++;
        continue;
      }
      sources.add(ProgressiveAudioSource(Uri.parse(url), tag: items[i]));
    }
    final dropped = items.length - sources.length;
    if (dropped > 0) {
      Get.log(
        'AudioPlayerHandler: $dropped 首取不到播放地址已从队列剔除 '
        '(VIP / 地区限制 / 未登录?)',
      );
    }
    return (
      sources,
      (startIndex - droppedBeforeStart).clamp(0, sources.length),
    );
  }

  // ---- 内部:播放/索引计算 -------------------------------------------------------

  /// 标记 [queueIndex] 这首起不来:emit idle/error 状态给上层。
  ///
  /// 数据源只有一个:[_audio] 的 `errorStream`。
  ///
  /// 老实现有两个来源(`setUrl` 同步抛 + `_playAt` 里 `fetchSongUrl` 返回 null
  /// 提前 return);现在 URL 解析搬到本机 302 server,handler 这层看不到
  /// "取不到地址"这件事 —— 它只表现为播放器的**异步**加载失败,只能靠这条流。
  /// 所以 errorStream 顺带覆盖了老路径的 404 / 超时 / CDN 拒绝。
  void _emitLoadError(String message, [StackTrace? st]) {
    final item = _currentItem;
    mediaItem.add(
      item == null
          ? null
          : item.copyWith(extras: {...?item.extras, 'loadError': message}),
    );
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.idle,
        controls: _buildControls(
          isCurrentSongLiked:
              item != null && _likedService.isLiked(item.id, LikedType.song),
        ),
        // audio_service exposes this as an integer (there is no
        // AudioServiceErrorCode enum in the version used by this project).
        errorCode: 0,
        errorMessage: message,
      ),
    );
    // 跟 playerStateStream listener 一样保留 stack,debug 时能看
    assert(() {
      // ignore: avoid_print
      print('AudioPlayerHandler: load failed at $item\n$message\n$st');
      return true;
    }());
  }

  /// 只读窥探下一首/上一首的 queue 索引 (不改状态)。
  /// 供 wrapper 的 nextIndex/prevIndex 转发,消除 wrapper 层重复的 shuffle 状态。
  ///
  /// just_audio 的 `nextIndex` / `previousIndex` 已经把 LoopMode(含头尾循环)和
  /// shuffle 顺序都算好了,直接问它就行。repeatOne 下返回当前自己 —— 与老实现
  /// 的 `_neighbor` 行为一致。
  int peekNeighbor(int delta) {
    final next = delta >= 0 ? _audio.nextIndex : _audio.previousIndex;
    return next ?? -1;
  }

  // ---- 锁屏 controls 构造 -------------------------------------------------------

  /// 三按钮基础 controls (不含 like)。like 按钮由 [_buildControls] 根据 isLiked 拼上。
  List<MediaControl> get _baseControls => const [
    MediaControl.skipToPrevious,
    MediaControl.play,
    MediaControl.skipToNext,
  ];

  /// 构造锁屏 controls。
  ///
  /// androidIcon 必须是 `@drawable/<name>` 或裸名字符串都能解析,
  /// audio_service 用 `applicationContext.getPackageName()` +
  /// `getResources().getIdentifier(name, "drawable", packageName)` 找。
  /// 不存在的资源会让 `PlaybackStateCompat$CustomAction$Builder.<init>` 抛
  /// IllegalArgumentException → AudioService.setState catch 后只打 stacktrace,
  /// 但 handler 内部 `playerStateStream` 每 200ms 都触发一次 rebuild controls,
  /// 主 isolate 进入 setState retry loop + logd 撞配额 → 打开 app 时 UI 冻屏
  /// (实际 audio 在播但 UI thread 被 stacktrace printing 占满)。
  /// 修复:对齐 res/drawable 实际文件名 (ic_favorite / ic_favorite_border,
  /// 不是 raw_favorite_border)。
  List<MediaControl> _buildControls({required bool isCurrentSongLiked}) {
    final playing = playbackState.value.playing;
    return [
      MediaControl.skipToPrevious,
      if (playing) MediaControl.pause else MediaControl.play,
      MediaControl.skipToNext,
      MediaControl(
        action: MediaAction.custom,
        label: isCurrentSongLiked ? '取消喜欢' : '喜欢',
        androidIcon: isCurrentSongLiked
            ? 'drawable/ic_favorite'
            : 'drawable/ic_favorite_border',
        customAction: const CustomMediaAction(name: 'toggleLike'),
      ),
    ];
  }

  AudioProcessingState _mapProcessingState(ProcessingState s) {
    switch (s) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }
}
