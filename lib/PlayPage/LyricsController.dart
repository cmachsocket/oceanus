import 'dart:async';
import 'dart:convert';

import '../models/Snapshot.dart' show PlaybackSnapshot;
import 'package:flutter_lyric/flutter_lyric.dart';
import 'package:get/get.dart';

import '../models/Song.dart';
import '../services/AudioPlayerWrapper.dart';
import 'package:get_storage/get_storage.dart';
import '../models/Lyrics.dart';

/// 歌词控制器 —— 直接订阅 [AudioPlayerService.snapshot] 拉歌词、推进度。
///
/// ## 依赖关系
///
/// **只依赖 [AudioPlayerService]**(音频 wrapper),不依赖 [PlayerController]。
///
/// 之前依赖 PlayerController 的原因:PlayerController 自己订阅 just_audio
/// stream 并维护 currentSong/position Rx,歌词想拿进度只能从那里读。但现在:
///   - 音频真相全部在 wrapper (snapshot.currentSong / snapshot.position)
///   - PlayerController 只是 wrapper 的 UI facade,本身不持有音频流
///
/// 既然 wrapper 已经直接暴露这些字段,LyricsController 不该再绕一层 facade
/// ——耦合 PlayerController 会导致:
///   1. 业务路径变长(UI → PlayerController → wrapper → handler → just_audio),
///      调试时不清楚该信哪一层的状态
///   2. LyricsController 跟 PlayerController 生命周期绑死(都 permanent: true
///      时不会出问题,但语义上歌词跟音频状态对齐,跟 UI facade 不该有依赖)
///
/// 改为直接订阅 wrapper.snapshot.stream,在回调里 diff 出 currentSong /
/// position 的变化,触发 lyric 加载 / 高亮推进。
///
/// 为什么不拆出 wrapper.currentSong / wrapper.position Rx:
///   - wrapper.snapshot 是单一真相,拆出 6+ 个 Rx 容易双写不同步
///   - 直接 stream.listen + 内部 diff 单测简单
///
/// 生命周期:
/// - **permanent: true** (main.dart 注册),跟 wrapper 同生命周期
/// - lyricController 实例跨切歌复用,跨页路由销毁
/// - permanent 是为了跨路由(从 PlayerPage 跳到 PlayListPage 再回来)LyricView
///   重新 mount 时能从 lyricNotifier.value 立刻拿到当前 lyric,不再重拉

enum LyricShowMode {
  translation, // 显示翻译歌词
  romaji, // 显示罗马拼音歌词
  original, // 显示原歌词(不显示次要歌词)
}

class LyricsController extends GetxController {
  static const lyricShowModeKey = 'lyric_show_mode_v1';
  final LyricController lyricController = LyricController();

  final AudioPlayerService _audio = Get.find<AudioPlayerService>();
  GetStorage get _box => GetStorage();

  /// 正在拉 lyric 的 song id (防止重复请求 — currentSong 流偶尔抖)
  String? _fetchingSongId;

  /// 当前持有的 lyric (UI 调试 / 备用 — flutter_lyric 主用 lyricNotifier)
  final Rxn<String> currentLyric = Rxn<String>();
  late final Rx<LyricShowMode> lyricShowMode;

  /// 上一次 snapshot 里的 currentSong / position,用于内部 diff 判断字段变化
  Song? _lastSong;
  Duration _lastPosition = Duration.zero;

  StreamSubscription<PlaybackSnapshot>? _snapshotSub;

  @override
  void onInit() {
    super.onInit();
    // 订阅 wrapper.snapshot 整体流,内部 diff 出当前歌 / 进度变化
    // snapshot 每次都 new 一份(PlayOrderSnapshot.copyWith),stream 等价 onChange,
    // 但我们只对 currentSong / position 字段变化感兴趣
    final storedName = _box.read<String>(lyricShowModeKey);
    final initialMode = LyricShowMode.values.firstWhere(
      (m) => m.name == storedName,
      orElse: () => LyricShowMode.original,
    );
    lyricShowMode = initialMode.obs;
    final initial = _audio.snapshot.value;
    _lastSong = initial.currentSong;
    _lastPosition = initial.position;
    _snapshotSub = _audio.snapshot.stream.listen(_onSnapshot);
    // 启动时主动触发一次(可能 wrapper 启动比 LyricsController 晚,
    // 初始 snapshot.currentSong 已经有值)
    _onSnapshot(initial);
    // 点击歌词行 → 直接 seek wrapper (不走 PlayerController facade)
    lyricController.setOnTapLineCallback(_audio.seek);
  }

  @override
  void onClose() {
    _snapshotSub?.cancel();
    super.onClose();
  }

  Future<void> switchLyric() async {
    final mode = switch (lyricShowMode.value) {
      LyricShowMode.original => LyricShowMode.translation,
      LyricShowMode.translation => LyricShowMode.romaji,
      LyricShowMode.romaji => LyricShowMode.original,
    };
    lyricShowMode.value = mode;
    _box.write(lyricShowModeKey, mode.name);
    await refreshCurrent();
  }

  /// snapshot 变化 → diff 出 currentSong / position 的字段级变化
  ///
  /// - currentSong 变 → 拉新歌词(触发 _onCurrentSongChanged)
  /// - position 变 → 推送给 flutter_lyric 做高亮 + 自动滚动
  /// - 同首歌同个 position 不重复触发(GetX snapshot.copyWith 每次都 new 对象,
  ///   stream 会 fire 一次,但内部 diff 让 lyric setProgress 是幂等操作,
  ///   多 fire 几次没问题;真正重的"fetch lyric"用 _fetchingSongId 防抖)
  void _onSnapshot(PlaybackSnapshot s) {
    final song = s.currentSong;
    if (song?.id != _lastSong?.id) {
      _onCurrentSongChanged(song);
    }
    _lastSong = song;

    if (s.position != _lastPosition) {
      lyricController.setProgress(s.position);
    }
    _lastPosition = s.position;
  }

  /// 用户手动刷新当前歌词 (UI "重试"按钮)
  Future<void> refreshCurrent() async {
    final song = _audio.snapshot.value.currentSong;
    if (song == null) return;
    await _loadLyricFor(song.id);
  }

  Future<void> _onCurrentSongChanged(Song? song) async {
    if (song == null) {
      _fetchingSongId = null;
      currentLyric.value = null;
      lyricController.loadLyric('');
      return;
    }
    await _loadLyricFor(song.id);
  }

  /// 用 lrc 的行时间覆写 yrc 的行时间(按**整行文本**匹配)
  ///
  /// ## 为什么需要对轴
  ///
  /// yrc(逐字歌词)的时间是自动打轴出来的,跟 lrc(整行歌词)对不上。以 lyric.json
  /// 那首歌为例,50 行里逐行偏移在 -1440ms ~ +6670ms 之间飘,同一句副歌前后能差
  /// 好几秒。直接用 yrc 会有两个后果:
  ///   - 行高亮跟人声对不上
  ///   - 翻译永远出不来 —— flutter_lyric 配翻译时走
  ///     `LrcParser.findTranslation(ms, tolerance: 10)`,而 tlyric / romalrc 都是
  ///     lrc 时间轴,10ms 容差下差几百毫秒必然查不到
  ///
  /// 所以以**文本**为准(lrc 的行文本就是这一行唱的内容)、以**时间**为准取 lrc,
  /// 拿 lrc 的行时间去盖 yrc 的行时间。
  ///
  /// ## 关键取舍
  ///
  /// - **逐字时间同步平移**: 只换行头会让逐字高亮(line 内按 word.start/word.end
  ///   画)和行高亮各走各的时间轴,反而更乱。delta 整体平移行内所有 `(start,dur,0)`
  ///   逐字时间,行内相对节奏保持不变。
  /// - **按出现顺序消费**: 副歌重复的同一句在 lrc 里有多个时间点,一一对应消费,
  ///   不会串台;对齐不了就保持 yrc 原值。
  /// - **只改时间,不改内容**: 没匹配上的行原样输出(逐字歌词是主内容,宁可少改
  ///   也别丢字),元信息行 `{"t":0,"c":[...]}` 也按整行文本一起对。
  ///
  /// 参数 [yrc] 是带 yrc 字段的完整响应,[lrc] 只用到它的 lrc 字段(缺省回退到
  /// [yrc] 自带的 lrc)。返回一个合并后的新 [Lyrics],yrc 是对齐后的文本。
  Lyrics alignLyrics(Lyrics yrc, Lyrics lrc) {
    final yrcText = yrc.yrc;
    final lrcText = lrc.lrc ?? yrc.lrc;
    // 没有 yrc 就没有逐字行可对;没有 lrc 就无从取时间。都直接原样返回。
    if (yrcText == null || yrcText.trim().isEmpty) return yrc;
    if (lrcText == null || lrcText.trim().isEmpty) return yrc;

    final index = _LrcTimeIndex.parse(lrcText);
    final result = StringBuffer();
    var total = 0;
    var aligned = 0;

    for (final raw in yrcText.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue; // 空行原样丢掉(yrc 结尾必带一个空行)

      // 元信息行: {"t":0,"c":[{"tx":"作词: "},{"tx":"稲葉曇"}]}
      // 整行内容是 tx 拼接,只把开头的 "t" 换掉,其余原样保留
      final meta = _yrcMetaRe.firstMatch(line);
      if (meta != null) {
        final text = _yrcMetaText(line);
        final lrcMs = text == null ? null : index.take(text);
        if (lrcMs != null) {
          total++;
          aligned++;
          result.writeln(
            '${meta.group(1)}$lrcMs${meta.group(3)}${line.substring(meta.end)}',
          );
        } else {
          result.writeln(line);
        }
        continue;
      }

      // 逐字行: [start,dur](start,dur,0)字(start,dur,0)字...
      final header = _yrcHeaderRe.firstMatch(line);
      if (header == null) {
        // 标签行 / 未知行: 原样透传
        result.writeln(line);
        continue;
      }
      final body = line.substring(header.end);
      final words = _yrcWordRe
          .allMatches(body)
          .map(
            (m) => _YrcWord(
              m.start,
              m.end,
              int.parse(m.group(1)!),
              m.group(2)!,
              m.group(3)!,
              m.group(4)!,
            ),
          )
          .toList();
      if (words.isEmpty) {
        // 有行头没内容(纯占位行),没文本可匹配,原样透传
        result.writeln(line);
        continue;
      }

      final text = words.map((w) => w.text).join();
      final lrcMs = index.take(text);
      total++;
      if (lrcMs == null) {
        // lrc 里没这一句(逐字版独有的行),保留 yrc 自己的时间
        result.writeln(line);
        continue;
      }
      aligned++;

      // 行头换成 lrc 时间,行内逐字时间平移同一个 delta
      final delta = lrcMs - int.parse(header.group(1)!);
      final shifted = StringBuffer();
      var cursor = 0;
      for (final w in words) {
        shifted.write(body.substring(cursor, w.start));
        final startMs = w.startMs + delta;
        shifted
          ..write('(${startMs < 0 ? 0 : startMs},${w.duration},${w.zero})')
          ..write(w.text);
        cursor = w.end;
      }
      shifted.write(body.substring(cursor));
      result.writeln('[$lrcMs,${header.group(2)}]$shifted');
    }

    Get.log('alignLyrics: $aligned/$total 行用 lrc 时间覆写 yrc');
    return Lyrics(
      lrc: yrc.lrc ?? lrc.lrc,
      tlyric: yrc.tlyric ?? lrc.tlyric,
      romalrc: yrc.romalrc ?? lrc.romalrc,
      yrc: result.toString(),
    );
  }

  Future<void> _loadLyricFor(String songId) async {
    // 防抖: 快速连续两次同一首不重拉
    if (_fetchingSongId == songId) return;
    _fetchingSongId = songId;

    final lyric = await _audio.fetchLyric(songId);
    // 期间可能切歌了 → 只对当前 songId 灌结果
    if (_fetchingSongId != songId) return;

    if (lyric == null) {
      currentLyric.value = null;
      lyricController.loadLyric('');
      return;
    }
    // 结束fetch,避免refreshCurrent时被防抖拦截
    _fetchingSongId = null;
    currentLyric.value = lyric.yrc ?? lyric.lrc ?? '';
    Get.log("${lyric.yrc}");
    Get.log("${lyric.tlyric}");
    // 一些歌只有 lrc(没有逐字版),有 yrc 的歌先用 lrc 的行时间覆写 yrc 再喂
    // flutter_lyric —— 行高亮跟人声对齐,翻译(tlyric/romalrc 都是 lrc 时间轴)
    // 也才配得上,否则 yrc 的自动打轴会差几百毫秒导致翻译全空
    final aligned = alignLyrics(lyric, Lyrics(lrc: lyric.lrc));
    lyricController.loadLyric(
      aligned.yrc ?? aligned.lrc ?? '',
      translationLyric: switch (lyricShowMode.value) {
        LyricShowMode.original => null,
        LyricShowMode.translation => aligned.tlyric,
        LyricShowMode.romaji => aligned.romalrc,
      },
    );
  }
}

/// yrc 逐字行里匹配到的一个 `(start,duration,zero)字` 片段
///
/// [start] / [end] 是它在**行内 body 字符串**中的偏移,回写时用来保留
/// 逐字匹配覆盖不到的杂字符(理论上不该有,但别把用户的词改没了)。
class _YrcWord {
  const _YrcWord(
    this.start,
    this.end,
    this.startMs,
    this.duration,
    this.zero,
    this.text,
  );

  /// 在 body 中的起始偏移
  final int start;

  /// 在 body 中的结束偏移
  final int end;

  /// 逐字开始时间(ms)
  final int startMs;

  /// 逐字时长(ms),原样回写
  final String duration;

  /// 零音量标记,原样回写
  final String zero;

  /// 逐字文本,拼接后即整行文本
  final String text;
}

/// yrc 行头 `[start,duration]`,start 单位 ms
final RegExp _yrcHeaderRe = RegExp(r'^\[(\d+),(\d+)\]');

/// yrc 逐字 `(start,duration,zero)字`,start 单位 ms
final RegExp _yrcWordRe = RegExp(r'\((\d+),(\d+),(\d+)\)([^(]*)');

/// yrc 元信息行行首 `{"t":<ms>,"c":[...]}`(作词/作曲等)
final RegExp _yrcMetaRe = RegExp(r'^(\{"t":)(\d+)(,)');

/// lrc 行头 `[mm:ss.xx]`,同一行可能带多个时间戳(重复歌词的简写写法)
final RegExp _lrcTimeRe = RegExp(r'\[(\d{1,}):(\d{2})(?:[.:](\d{1,}))?\]');

/// 取 yrc 元信息行的整行文本(json 里所有 `tx` 拼接)
///
/// 解析不了返回 null(此时该行不参与对齐),不抛 —— 上游字段偶尔有脏数据。
String? _yrcMetaText(String line) {
  try {
    final decoded = jsonDecode(line);
    if (decoded is! Map) return null;
    final contents = decoded['c'];
    if (contents is! List) return null;
    return contents
        .whereType<Map<String, dynamic>>()
        .map((item) => item['tx'])
        .whereType<String>()
        .join();
  } catch (_) {
    return null;
  }
}

/// lrc 文本 → 行时间索引,供 alignLyrics 按整行文本取时间
///
/// - 同一文本出现多次时(副歌),按出现顺序排队消费,避免各段副歌互相串时间
/// - [_byLooseText] 是空白压缩后的兜底索引,与 [_byText] **共用同一批 List**,
///   兜底消费掉的条目不会再被精确匹配拿走
class _LrcTimeIndex {
  _LrcTimeIndex(this._byText, this._byLooseText);

  final Map<String, List<int>> _byText;
  final Map<String, List<int>> _byLooseText;

  static final RegExp _spaceRe = RegExp(r'[ \t　]+');

  factory _LrcTimeIndex.parse(String lrc) {
    final byText = <String, List<int>>{};
    for (final raw in lrc.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final tags = _lrcTimeRe.allMatches(line).toList();
      // 没有时间戳 = 标签行 / 空标签,不参与匹配
      if (tags.isEmpty) continue;
      var text = line;
      final times = <int>[];
      for (final tag in tags) {
        times.add(_lrcTimeMs(tag));
        text = text.replaceFirst(tag.group(0)!, '');
      }
      byText.putIfAbsent(text, () => <int>[]).addAll(times);
    }

    final byLoose = <String, List<int>>{};
    for (final entry in byText.entries) {
      byLoose.putIfAbsent(_loose(entry.key), () => entry.value);
    }
    return _LrcTimeIndex(byText, byLoose);
  }

  /// 取一行文本对应的 lrc 行时间(ms),取过即消费;没有则 null
  int? take(String text) {
    final candidates = [_byText[text], _byLooseText[_loose(text)]];
    for (final times in candidates) {
      if (times != null && times.isNotEmpty) return times.removeAt(0);
    }
    return null;
  }

  /// 空白压缩:逐字版拼接时不带空格,lrc 里可能手滑多打了空格/全角空格
  static String _loose(String text) => text.replaceAll(_spaceRe, ' ').trim();
}

/// `[mm:ss.xx]` → ms(与 flutter_lyric LrcParser.extractLine 同一套规则:
/// 不足 3 位的小数右侧补 0,超过 3 位截断)
int _lrcTimeMs(RegExpMatch tag) {
  final minutes = int.parse(tag.group(1)!);
  final seconds = int.parse(tag.group(2)!);
  final fraction = tag.group(3) ?? '';
  final ms = fraction.isEmpty
      ? 0
      : int.parse(fraction.padRight(3, '0').substring(0, 3));
  return minutes * 60000 + seconds * 1000 + ms;
}
