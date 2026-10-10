import 'dart:async';
import '../models/Snapshot.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../SettingsPage/SettingsController.dart';
import 'LikedController.dart';
import 'LocalRedirectServer.dart';
import 'repositories/SongRepository.dart';

/// ---- 后台播放 handler (audio_service + just_audio 桥接) ------------------------
///
/// 职责:
///
///   1. 订阅 [_audio] 的 5 个原生 stream,转发给 audio_service 广播:
///        - playerStateStream       → playbackState.add()
///        - currentIndexStream      → mediaItem.add(根据 _queue[index])
///        - durationStream          → mediaItem.add(更新 duration)
///        - positionStream          → playbackState.add(更新 position)
///        - bufferedPositionStream  → playbackState.add(更新 bufferedPosition)
///   2. 接收 audio_service 系统控制 (play/pause/seek/skip/customAction)
///      并翻译成 just_audio 操作
///   3. 维护 *唯一* 的可变状态: [_queue] / [_currentIndex] / [_playOrder] / [_shuffleOrder]
///   shuffle 模式下 [_shuffleOrder] 是 _queue 的随机排列,_currentIndex 始终是 _queue 索引
///
/// 设计原则:
///
///   - **不持有派生状态**: isLiked / currentSong 都不在这里存,由上层包装器从 stream 聚合
///   - **不双写**: queue / playbackState / mediaItem 都是 _audio 的派生态,不手动管理
///   - **shuffle 用映射表**: shuffleMap[playOrderIndex] = queueIndex,currentIndex 始终指
///     播放顺序的位置,内部翻成 queue 索引去读 _queue
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
    _queue = List.of(initialQueue);
    _currentIndex = initialIndex;
    _playOrder = initialMode;
    _rebuildShuffleMaps();

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
    // wrapper 订阅后立即拿到初始队列与当前歌, 真相状态在 handler 落地
    // 跟 super.updateQueue 同样的原因: audio_service QueueHandler.updateQueue
    // 内部对 nvalue 做原地修改, 这里 add 的 list 会被缓存进 nvalue, 之后
    // 任何 setQueue/updateQueue 调用都会因为 replaceRange unmodifiable 抛错。
    // 所以推可变 list 进去 (用 .toList() 防止外部后续改 _queue 影响 nvalue)。
    queue.add(_queue.toList());
    mediaItem.add(_currentItem);
    // playOrder 是 broadcast (无 replay): handler 构造时 emit 一次初始值,
    // wrapper 订阅后立刻拿到 (或在 onInit 里调 refreshPlayOrder 兜底)。
    // 之所以不用 BehaviorSubject 是因为 mode 只有 3 个枚举值, 没有"replay
    // 历史"语义, broadcast 更轻量。
    _playOrderCtrl.add(_playOrder);

    _wireAudioStreams();
  }

  // ---- 依赖 ---------------------------------------------------------------------

  final SongRepository _songRepo;
  final LikedController _likedService;

  /// 全局音质偏好 (用户设置) —— 在 [_playAt] 拉 URL 时取当前值传给
  /// [SongRepository.fetchSongUrl], 走 `/song/url/v1` 接口。
  /// 改值不需要重启 handler, 下一次 _playAt 自动读到新值。
  final SettingsController _settings;

  /// 本机 302 定向 server —— [_playAt] 把"给 just_audio 的地址"交给它生成。
  ///
  /// 开启时 handler **不再自己解析真 URL**:拿的是
  /// `http://localhost:<port>/s/<songId>/xxx?q=<level>` 这种稳定地址,真地址由
  /// server 在 prepare 那一刻解析并 302 出去 —— 网易云直链只有 ~20min 寿命,
  /// 提前解析存进队列的话排到队尾必过期。
  ///
  /// server 没起来 (端口被占 / web) 时 [LocalRedirectServer.enabled] 为 false,
  /// [_playAt] 退回自己 `fetchSongUrl` 直连,行为跟引入 server 之前完全一致。
  final LocalRedirectServer _redirect;

  final AudioPlayer _audio = AudioPlayer();

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
  /// 设计: 跟 currentSongLiked 一样,handler 是真相持有者 ([_playOrder] 私有
  /// 字段),改完模式后主动 emit, wrapper 只订阅不写自己的 Rx。
  /// 这样 wrapper.setPlayOrder 只是个 forward (audioHandler.setPlayOrder(...)),
  /// _playOrderSub 的更新全部由这条流驱动 — 单一真相源, 严格单向流。
  final StreamController<PlayOrder> _playOrderCtrl =
      StreamController<PlayOrder>.broadcast();

  /// 公开给 wrapper 订阅 (handler 主动 emit 播放顺序)
  Stream<PlayOrder> get playOrder => _playOrderCtrl.stream;

  /// 主动刷一次当前 playOrder (broadcast 无 replay, wrapper 订阅后兜底用)
  void refreshPlayOrder() => _playOrderCtrl.add(_playOrder);

  /// 释放 handler 持有的订阅 (handler dispose 时由 audio_service 框架调用)
  void dispose() {
    _likedSongIdsSub?.cancel();
    _likedSongIdsSub = null;
    _currentSongLikedCtrl.close();
    _playOrderCtrl.close();
  }

  // ---- 唯一可变状态 -------------------------------------------------------------

  /// 逻辑队列 (UI 显示顺序)。
  /// 当前架构下 just_audio 用 setUrl() 单曲驱动，不维护自己的 playlist。
  /// 所以 [_currentIndex] 始终是 _queue 里的索引，shuffle 由 [_shuffleOrder]
  /// (一个 _queue.length 的随机排列) 控制。
  List<MediaItem> _queue = [];
  int _currentIndex = -1;
  PlayOrder _playOrder = PlayOrder.sequential;

  /// shuffle 顺序:第 i 个要播的是 _queue[_shuffleOrder[i]]。
  /// 非 shuffle 模式时 = [_queue] 的恒等排列 (List.generate(i, i))。
  List<int> _shuffleOrder = [];

  /// shuffle 反向映射:_shufflePosOfQueueIndex[queueIdx] = shufflePos。
  /// 让 [_neighbor] 在 shuffle 模式下 O(1) 查当前歌的播放顺序位置,
  /// 也让 [removeQueueItemAt] 在 shuffle 模式下做"顺序保持"的稳定删除,
  /// 而不是重洗整个队列 (重洗会让用户在听 shuffle 时删歌后听到不同的歌)。
  /// 非 shuffle 模式时为空 (sequential 不需要反向查)。
  List<int> _shufflePosOfQueueIndex = [];

  /// 当前播放的 MediaItem（== _queue[_currentIndex]，带边界保护）。
  MediaItem? get _currentItem =>
      (_currentIndex >= 0 && _currentIndex < _queue.length)
      ? _queue[_currentIndex]
      : null;

  /// 只读暴露给 wrapper 的 _persist 用 (避开 Rx 异步滞后的旧值)。
  int get persistedIndex => _currentIndex;
  PlayOrder get persistedMode => _playOrder;
  List<MediaItem> get persistedQueue => List.unmodifiable(_queue);
  // 注:不再暴露 currentIndex 字段。wrapper 从 mediaItem.extras['queueIndex']
  // 读取当前索引,handler 在 [_playAt] / [removeQueueItemAt] 等"换索引"的地方
  // 把新索引写进对应 [MediaItem.extras] 并随 [mediaItem.add] emit。

  // ---- 订阅接线 (在构造里跑一次) -------------------------------------------------

  void _wireAudioStreams() {
    // 1. 播放状态 → playbackState + 自动跳下一首
    _audio.playerStateStream.listen((state) {
      // liked 状态查 _likedService.isLiked (实时查,不缓存);
      // 切歌后的 likes 同步走 _emitCurrentSongLiked (在 _playAt 末尾调),
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
      // 自然播完 → 自动下一首
      //
      // - just_audio 在 setUrl 单曲驱动模式下:currentIndexStream 永远 = 0,
      //   它**不会**在 playlist 走完时自动 skipToNext(那是 ConcatenatingAudioSource
      //   的行为),所以这里手动监听 completed → 调 _neighbor(1) 推进。
      // - sequential: +1 wrap;shuffle: 走 _shuffleOrder;repeatOne: 返回
      //   _currentIndex → 重播同首(走 _playAt 重新 prepare + play)。
      // - 无需防抖:skipToNext → _playAt → _audio.setUrl → processingState
      //   立刻进 loading/idle,不会再回 completed,不存在循环。
      // - **handler 内做**而不是 wrapper/PlayerController:handler 是 just_audio
      //   流唯一订阅者,生命周期跟 app 同步,无 PlayerController 销毁后
      //   自动切歌失效的隐患。
      if (state.processingState == ProcessingState.completed) {
        final next = _neighbor(1);
        if (next >= 0) {
          // ignore: discarded_futures
          _playAt(next);
        }
      }
    });

    // 2. 当前索引 → mediaItem
    // 注意: setUrl() 模式下 just_audio.currentIndexStream 永远 = 0
    // 所以这里 *不* 用 currentIndexStream 做真相,_currentIndex 由 _playAt() 显式更新
    // currentIndexStream 只用来 *检测* skipToNext() 这类操作是否被 just_audio 内部消化
    // (供调试/扩展用,这里不依赖它)
    _audio.currentIndexStream.listen((_) {});

    // 3. 时长变化 → 更新当前 MediaItem 的 duration
    _audio.durationStream.listen((dur) {
      if (dur == null) return;
      final item = _currentItem;
      if (item == null) return;
      if (item.duration == dur) return; // 没变就别 add (避免无效广播)
      final updated = item.copyWith(duration: dur);
      // 同步更新 _queue 里这份 (媒体时长是只读属性,放 extras 也行,这里直接改 MediaItem)
      _queue[_currentIndex] = updated;
      mediaItem.add(updated);
    });

    // 4. 位置流 → playbackState (audio_service 锁屏进度条需要)
    _audio.positionStream.listen((pos) {
      playbackState.add(playbackState.value.copyWith(updatePosition: pos));
    });

    // 5. 缓冲位置
    _audio.bufferedPositionStream.listen((buf) {
      playbackState.add(playbackState.value.copyWith(bufferedPosition: buf));
    });

    // 6. 加载错误 → 走跟 setUrl 抛异常完全相同的失败路径
    //
    // 为什么必须有这条:302 路径下 `_audio.setUrl(本机地址)` **不会抛** ——
    // server 只会回 302(成功)或 404(取不到地址),两种都是 HTTP 层正常返回。
    // "这首起不来"变成播放器异步报的错,只在这里能观察到。以前靠
    // `_playAt` 里 `fetchSongUrl` 返回 null 提前 return 来 fail-fast,
    // 现在真地址解析在 server 里,handler 这层看不到,只能靠 errorStream。
    _audio.errorStream.listen((e) {
      final idx = _currentIndex;
      if (idx < 0 || idx >= _queue.length) return;
      _emitLoadError(idx, 'load failed: ${e.message} (${e.code})');
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

  Future<void> setQueue(List<MediaItem> newQueue, {int startIndex = 0}) async {
    if (newQueue.isEmpty) {
      _queue = [];
      _shuffleOrder = [];
      _shufflePosOfQueueIndex = [];
      _currentIndex = -1;
      mediaItem.add(null);
      queue.add(const []);
      await _audio.stop();
      return;
    }
    _queue = List.of(newQueue);
    _rebuildShuffleMaps();

    final clampedStart = startIndex.clamp(0, _queue.length - 1);
    await _playAt(clampedStart);
    // 传 _queue.toList() 而不是 List.unmodifiable(_queue):
    // audio_service QueueHandler.updateQueue 内部对传入 list 做 replaceRange
    // 原地修改, 传 unmodifiable 第二次调用就会抛
    // "Cannot remove from an unmodifiable list" (这个 list 会被缓存进 nvalue)。
    // 这里 _queue 本身就是可变的 List, 直接给一个浅拷贝即可。
    await super.updateQueue(_queue.toList());
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (_queue.isEmpty) return;
    if (index < 0 || index >= _queue.length) return;
    await _playAt(index);
  }

  @override
  Future<void> skipToNext() async {
    if (_queue.isEmpty) return;
    final next = _neighbor(1);
    if (next < 0) return;
    await _playAt(next);
  }

  @override
  Future<void> skipToPrevious() async {
    if (_queue.isEmpty) return;
    final prev = _neighbor(-1);
    if (prev < 0) return;
    await _playAt(prev);
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    if (_queue.isEmpty) return;
    if (index < 0 || index >= _queue.length) return;

    final wasCurrent = index == _currentIndex;
    _queue.removeAt(index);
    if (_queue.isEmpty) {
      _shuffleOrder = [];
      _shufflePosOfQueueIndex = [];
      _currentIndex = -1;
      mediaItem.add(null);
      queue.add(const []);
      await _audio.stop();
      return;
    }

    // shuffle 模式下做"稳定删除":保持剩余歌曲在 shuffle 序列中的相对顺序,
    // 而不是每次都重洗 (重洗会让用户听到不同的歌)。
    //   - 正向表 _shuffleOrder: 删掉 _shufflePosOfQueueIndex[index] 那项,后续 -1
    //   - 反向表 _shufflePosOfQueueIndex: index 之后的所有项 -1
    if (_playOrder == PlayOrder.shuffle) {
      _removeFromShuffleMaps(index);
    } else {
      // sequential 模式不用维护反向表;_shuffleOrder 是恒等映射也不需要重生成
    }

    if (wasCurrent) {
      // 移除的是当前:从头开始播 (走 _playAt,会在 extras 写 queueIndex=0)
      _currentIndex = -1;
      await _playAt(0);
    } else {
      // 调整 currentIndex,重发当前 mediaItem (带新 queueIndex)
      if (index < _currentIndex) {
        _currentIndex--;
        _queue[_currentIndex] = _queue[_currentIndex].copyWith(
          extras: {
            ...?_queue[_currentIndex].extras,
            'queueIndex': _currentIndex,
          },
        );
        mediaItem.add(_queue[_currentIndex]);
        // _currentItem 还是同一首歌,只是 index 调整 — isCurrentSongLiked
        // 的值没变,这里不重复 emit (wrapper 那边 isCurrentSongLiked 也不会变)
      }
      // 删除后面的歌:_currentIndex 不变,queue 已经更新,wrapper 通过 _onQueue 收新列表
    }
    // 跟 setQueue 同样的原因: audio_service QueueHandler.updateQueue 内部
    // 会对 nvalue 做原地修改, 不能传 unmodifiable (会抛 "Cannot remove from
    // an unmodifiable list" 且 nvalue 缓存了 unmodifiable 之后所有路径都炸)
    await super.updateQueue(_queue.toList());
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    // 系统/外部调用 (锁屏 widget 拖队列等) 会走这里
    // 我们信任 caller,直接接管
    await setQueue(queue, startIndex: _currentIndex.clamp(0, queue.length - 1));
  }

  /// 单曲 append 到队列末尾(不打断当前播放)。
  ///
  /// **为什么 override `QueueHandler` 默认实现**:
  /// 默认 `QueueHandler.addQueueItem` 只 emit `queue.add()`,**不**更新
  /// handler 内部的 `_queue` 字段和 shuffle 索引 —— wrapper 那边 `playlist`
  /// RxList 不会变(shuffle 模式下 next/prev 也会算错,因为 `_shuffleOrder`
  /// 跟实际长度对不上)。
  ///
  /// **正确流程**:
  ///   1. `_queue.add(item)` 维护内部队列
  ///   2. `_rebuildShuffleMaps()` 重生成 shuffle 顺序 + 反向映射
  ///   3. `super.updateQueue(_queue.toList())` 推给 audio_service + 触发
  ///      wrapper 那边 `_onQueue` 同步 `playlist` RxList
  ///
  /// **不调 `_playAt`**:addQueueItem 的语义是"队列加一首",不是"跳到这首"
  /// —— 跟 `skipToQueueItem` 区分清楚。
  ///
  /// **未真机校准**:shuffle 模式下 addQueueItem 后,_currentIndex 不动,
  /// 后续 skipToNext 会按新 shuffle 顺序走;如果是 sequential 模式,完全
  /// 不影响 _currentIndex。如果 UI 出 bug(比如队列列表没刷新,或 shuffle
  /// 听歌顺序不对),贴 `addQueueItem` 触发后的日志给我看。
  @override
  Future<void> addQueueItem(MediaItem item) async {
    _queue.add(item);
    _rebuildShuffleMaps();
    // 跟 setQueue 同样的原因:audio_service QueueHandler.updateQueue 内部
    // 对 nvalue 做原地修改, 不能传 unmodifiable list (会抛 Cannot remove
    // from an unmodifiable list 且 nvalue 缓存 unmodifiable 之后所有路径都炸)。
    await super.updateQueue(_queue.toList());
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
    _playOrder = order;
    // 切模式后重生成 shuffle 表 + 反向表
    _rebuildShuffleMaps();
    // currentIndex 已经是 queue 索引,不需要变
    // 推 wrapper 同步展示层 Rx (handler 是唯一真相源, _playOrderSub 由这条流镜像)
    _playOrderCtrl.add(order);
  }

  /// (re)build shuffle 模式下的 _shuffleOrder 和 _shufflePosOfQueueIndex。
  /// - shuffle: 正向洗,反向跟着建
  /// - 其他: 正向恒等,反向留空 (sequential / repeatOne 不查反向)
  void _rebuildShuffleMaps() {
    if (_playOrder == PlayOrder.shuffle) {
      _shuffleOrder = List.generate(_queue.length, (i) => i)..shuffle();
      _shufflePosOfQueueIndex = List.filled(_queue.length, -1);
      for (var pos = 0; pos < _shuffleOrder.length; pos++) {
        _shufflePosOfQueueIndex[_shuffleOrder[pos]] = pos;
      }
    } else {
      _shuffleOrder = List.generate(_queue.length, (i) => i);
      _shufflePosOfQueueIndex = [];
    }
  }

  /// 删 queueIndex=idx 的一首,在 shuffle 模式下做稳定删除。
  ///
  /// 操作:
  ///   1. 在 _shuffleOrder 里 removeAt(pos),其中 pos = _shufflePosOfQueueIndex[idx]
  ///   2. _shuffleOrder 里所有 > idx 的项 (queueIdx > idx 都已 -1) 需要 -1
  ///   3. _shufflePosOfQueueIndex removeAt(idx) (queueIdx 之后整体前移)
  ///   4. _shufflePosOfQueueIndex 里所有指向已删除项的 (越界) 清 -1,
  ///      其余保持原值 (它们的 shufflePos 没变,queueIdx 减了 1 但 pos 还指向同一个 shufflePos)
  ///
  /// 复杂度 O(n) (两表一次扫描),但不需要调 .shuffle(),剩余歌曲在 shuffle
  /// 序列中的相对顺序保持不变。
  void _removeFromShuffleMaps(int idx) {
    if (_shufflePosOfQueueIndex.length != _queue.length + 1) {
      // 防御: 长度对不上 (说明 _queue.removeAt 还没调或别的状态错误),重生成
      _rebuildShuffleMaps();
      return;
    }
    final pos = _shufflePosOfQueueIndex[idx];
    if (pos < 0 || pos >= _shuffleOrder.length) {
      _rebuildShuffleMaps();
      return;
    }
    // 1. 正向表删 pos
    _shuffleOrder.removeAt(pos);
    // 2. 正向表里 > idx 的项减 1 (queue 缩短了 1,这些项对应的 queueIdx 也 -1)
    for (var i = 0; i < _shuffleOrder.length; i++) {
      if (_shuffleOrder[i] > idx) _shuffleOrder[i]--;
    }
    // 3. 反向表删 idx (queueIdx 之后整体前移一格)
    _shufflePosOfQueueIndex.removeAt(idx);
    // 4. 反向表里 > pos 的项保持原值 (它们指向同一个 shufflePos,shuffleOrder 已删除 pos 那项,pos+1 现在在原 pos 位置 ——但 pos 是 shufflePos,反向表存的是 shufflePos,不动)
    //     实际上反向表里存的是 "queueIdx → shufflePos",queueIdx 删除后,后续 queueIdx -1 了,但 shufflePos 没变。
    //     反向表下标已经代表"新的 queueIdx" (第 3 步 removeAt(idx) 后),所以原 queueIdx K (K>idx) 现在在下标 K-1。
    //     它存的 shufflePos 还指向原 shufflePos,shuffleOrder 里那个 shufflePos 还在 (步骤 1 没动它,只删了 pos 那项) → OK 不需要改
  }

  // ---- 内部:播放/索引计算 -------------------------------------------------------

  /// 播放 [queueIndex] 对应的歌。会把 queueIndex 写进 extras (wrapper 从
  /// mediaItem 流读 currentIndex 用)。
  ///
  /// 播放地址有两条路:
  /// - **本机 302(默认)**:拿 [LocalRedirectServer.urlFor] 生成的稳定地址直接
  ///   setUrl,真地址由 server 在 prepare 那一刻解析。好处是排队久了也不会过期,
  ///   而且这条路径是同步的 —— 不存在"await 期间用户切歌"的 stale 竞态。
  /// - **直连真地址(server 没起来时)**:自己 `fetchSongUrl`,保留 stale 校验。
  Future<void> _playAt(int queueIndex) async {
    if (queueIndex < 0 || queueIndex >= _queue.length) return;
    _currentIndex = queueIndex;

    final songId = _queue[queueIndex].id;
    final quality = _settings.currentQuality.value.name;

    String? url;
    if (_redirect.enabled) {
      // 同步生成,没有 await 窗口 → 下面不需要 stale 校验
      url = _redirect.urlFor(songId: songId, quality: quality).toString();
    } else {
      // 降级路径:按当前用户音质偏好直接拉真实 url
      url = await _songRepo.fetchSongUrl(songId, level: quality);
      if (url == null) return; // 取不到 URL 直接放弃 (上层 snackbar 另说)
      // stale request 校验: await 期间用户可能又切了别的歌,
      // 此刻 _currentIndex 已不是本次目标,丢弃这个过期的 fetch 结果
      if (_currentIndex != queueIndex) return;
    }
    // 注意:这里写进 extras 的可能是本机 302 地址而不是 CDN 真地址
    // (当前没有消费方读 extras['url'],保留只是为了调试时能看到实际 prepare 的东西)
    _queue[queueIndex] = _queue[queueIndex].copyWith(
      extras: {
        ...?_queue[queueIndex].extras,
        'url': url,
        'queueIndex': queueIndex,
      },
    );

    // setUrl 内部走 prepare,会因地址失效 / VIP / 地区限制 / 临时 5xx 抛
    // PlatformException (codec 0 = SourceError)。不 catch 会沿 main.dart 的
    // Get.putAsync await 链冒泡,GetX putAsync 不吞 future 异常 → app 启动
    // 直接 unhandled 崩。这里 catch 后 emit idle playbackState,wrapper 端 UI 能
    // 感知到失败;具体要不要自动 skipToNext 由 wrapper/UI 层决定
    // (handler 不替上层做播放策略, 单向流)。
    try {
      await _audio.setUrl(url);
    } catch (e, st) {
      // stale 校验同上面: await 期间用户切歌就丢弃这次失败,别污染当前状态
      if (_currentIndex != queueIndex) return;
      _emitLoadError(queueIndex, 'setUrl failed: $e', st);
      return;
    }

    mediaItem.add(_queue[queueIndex]);

    // repeatOne 不需要重新 prepare;sequential/shuffle 已经在 setUrl 后 just_audio
    // 会自动从 0 开始播,这里主动 play() 保证立即开始
    if (_playOrder != PlayOrder.repeatOne) {
      await _audio.play();
    } else {
      // repeatOne 但不是同一首 (从外部点过来的):重新 prepare 然后播
      await _audio.play();
    }

    // 切歌完成,同步当前歌的 liked 状态给 wrapper (修复: 旧实现只在
    // likedSongIds 变化时 emit,切歌后 isCurrentSongLiked 会停留在旧值)
    _emitCurrentSongLiked();
  }

  /// 标记 [queueIndex] 这首起不来:写 extras.loadError + emit idle/error 状态
  ///
  /// 两个来源共用:
  /// - [_playAt] 里 `setUrl` 同步抛异常
  /// - [_audio] 的 `errorStream` —— 302 路径下 setUrl **不会**抛(server 总是
  ///   返回 302 或 404),取不到地址/被 CDN 拒是播放器异步报错,只能走这条流。
  ///   旧路径(直连真地址)同样受益:404/超时也是异步来的。
  void _emitLoadError(int queueIndex, String message, [StackTrace? st]) {
    _queue[queueIndex] = _queue[queueIndex].copyWith(
      extras: {...?_queue[queueIndex].extras, 'loadError': message},
    );
    mediaItem.add(_queue[queueIndex]);
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.idle,
        controls: _buildControls(
          isCurrentSongLiked: _likedService.isLiked(
            _queue[queueIndex].id,
            LikedType.song,
          ),
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
      print(
        'AudioPlayerHandler: load failed at idx=$queueIndex\n$message\n$st',
      );
      return true;
    }());
  }

  /// 只读窥探下一首/上一首的 queue 索引 (不改状态)。
  /// 供 wrapper 的 nextIndex/prevIndex 转发,消除 wrapper 层重复的 shuffle 状态。
  int peekNeighbor(int delta) => _neighbor(delta);

  /// 计算下一个/上一个 [_queue] 索引。
  ///
  /// - repeatOne: 不变 (同首)
  /// - sequential: [_currentIndex] ± 1, 头尾循环
  /// - shuffle:    在 [_shuffleOrder] 序列里往后/前走一步
  ///              (先找到当前在序列中的位置 pos, 取 _shuffleOrder[(pos + delta + n) % n])
  int _neighbor(int delta) {
    if (_queue.isEmpty) return -1;
    final n = _queue.length;
    switch (_playOrder) {
      case PlayOrder.repeatOne:
        return _currentIndex;
      case PlayOrder.sequential:
        return (_currentIndex + delta + n) % n;
      case PlayOrder.shuffle:
        if (_shufflePosOfQueueIndex.isEmpty ||
            _shufflePosOfQueueIndex.length != n) {
          // 防御: 反向表长度对不上就重建
          _rebuildShuffleMaps();
        }
        final pos =
            _currentIndex >= 0 && _currentIndex < _shufflePosOfQueueIndex.length
            ? _shufflePosOfQueueIndex[_currentIndex]
            : -1;
        if (pos < 0) {
          // 当前不在序列里 (队列刚改),重洗后从当前开始
          _rebuildShuffleMaps();
          return _currentIndex;
        }
        final nextPos = (pos + delta + n) % n;
        return _shuffleOrder[nextPos];
    }
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
