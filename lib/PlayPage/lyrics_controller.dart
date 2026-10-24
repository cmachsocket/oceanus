import 'dart:async';
import 'dart:convert';

import '../models/snapshot.dart' show PlaybackSnapshot;
import 'package:flutter_lyric/flutter_lyric.dart';
import 'package:get/get.dart';

import '../models/song.dart';
import '../services/audio_player_wrapper.dart';
import 'package:get_storage/get_storage.dart';
import '../models/lyrics.dart';

/// 歌词控制器:订阅 [AudioPlayerService.snapshot],在回调里 diff 出
/// currentSong / position 的变化,拉歌词 + 推进高亮。
///
/// 只依赖 wrapper 不依赖 PlayerController(音频真相全在 snapshot),也不再拆
/// currentSong / position 的单独 Rx(snapshot 已是单一真相,再拆容易双写不同步)。
///
/// 生命周期:permanent(main.dart 注册)。跨路由返回时 LyricView 重新 mount 能从
/// `lyricNotifier.value` 直接拿到当前 lyric,不用重拉。

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
    // snapshot 每次都 new 一份(stream 等价 onChange),但我们只关心
    // currentSong / position 两个字段的变化
    final storedName = _box.read<String>(lyricShowModeKey);
    final initialMode = LyricShowMode.values.firstWhere(
      (m) => m.name == storedName,
      orElse: () => LyricShowMode.original,
    );
    lyricShowMode = initialMode.obs;
    final initial = _audio.snapshot.value;
    _lastPosition = initial.position;
    // ⚠️ `_lastSong` **故意留 null**。[_onSnapshot] 靠"歌变了"
    // (song?.id != _lastSong?.id)触发加载,而下面这行是补"启动这一刻的快照"
    // —— wrapper 注册在 LyricsController 之前,恢复出来的那首歌早就在 snapshot
    // 里了,变化事件早就发过,没人再通知。先填上就会让首次 diff 恒为 false,
    // 启动时缓存的歌永远不加载歌词。
    _snapshotSub = _audio.snapshot.stream.listen(_onSnapshot);
    _onSnapshot(initial);
  }

  @override
  void onClose() {
    _snapshotSub?.cancel();
    lyricController.dispose();
    super.onClose();
  }

  Future<void> seekToLyric(Duration position) => _audio.seek(position);

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

  /// currentSong 变 → 拉新歌词;position 变 → 推给 flutter_lyric 做高亮 + 滚动。
  /// snapshot.copyWith 每次都 new 对象,stream 会多 fire 几次,但 setProgress 幂等,
  /// 真正重的 fetch 由 _fetchingSongId 防抖。
  void _onSnapshot(PlaybackSnapshot s) {
    final song = s.currentSong;
    if (song?.id != _lastSong?.id) {
      _onCurrentSongChanged(song);
    }
    _lastSong = song;

    if (s.position != _lastPosition) {
      lyricController.setPosition(s.position);
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
      lyricController.clear();
      return;
    }
    await _loadLyricFor(song.id);
  }

  /// 按**整行文本**匹配,用 lrc 的行时间覆写 yrc 的行时间。
  ///
  /// yrc 逐字时间是自动打轴的,跟 lrc 对不上(实测 50 行偏移在 -1440ms ~ +6670ms
  /// 之间飘),直接用会让行高亮跟人声错位,而且翻译永远查不到(tlyric / romalrc
  /// 是 lrc 时间轴,flutter_lyric 容差只有 10ms)。所以以文本对齐、以 lrc 的时间为准。
  ///
  /// 取舍:逐字时间整体平移(只换行头会让两种高亮各走各的轴);重复句按出现顺序
  /// 消费(一一对应,不串台);只改时间不改内容(没匹配上的行原样输出,宁可少改别丢字)。
  ///
  /// [lrc] 只用到它的 lrc 字段(缺省回退到 [yrc] 自带的 lrc)。返回合并后的新
  /// [Lyrics],yrc 是对齐后的文本。
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
      lyricController.clear();
      return;
    }
    // 结束fetch,避免refreshCurrent时被防抖拦截
    _fetchingSongId = null;
    currentLyric.value = lyric.yrc ?? lyric.lrc ?? '';
    Get.log("[lyric] yrc: ${lyric.yrc}");
    Get.log("[lyric] lrc: ${lyric.lrc}");
    Get.log("[lyric] tlyric: ${lyric.tlyric}");

    // 一些歌只有 lrc(没有逐字版),有 yrc 的歌先用 lrc 的行时间覆写 yrc 再喂
    // flutter_lyric —— 行高亮跟人声对齐,翻译(tlyric/romalrc 都是 lrc 时间轴)
    // 也才配得上,否则 yrc 的自动打轴会差几百毫秒导致翻译全空
    final aligned = alignLyrics(lyric, Lyrics(lrc: lyric.lrc));
    Get.log("[Lyric] loaded : ${_mainLyric(aligned)}");
    lyricController.load(
      _mainLyric(aligned),
      translation: switch (lyricShowMode.value) {
        LyricShowMode.original => null,
        LyricShowMode.translation => _translation(aligned),
        LyricShowMode.romaji => _nonBlank(aligned.romalrc),
      },
    );
  }

  /// 翻译歌词(romaji 同理):非空白才给,并且**先把时间轴对齐到 lrc**。
  String? _translation(Lyrics aligned) {
    final t = _realLyric(aligned.tlyric);
    if (t == null) return null;
    return _alignTranslationToLrc(_realLyric(aligned.lrc), t);
  }

  /// 把 tlyric 的行时间戳改写成主歌词(lrc)的时间戳 —— **精度无关**。
  ///
  /// flutter_lyric 配翻译的两条路径容差不同:`YrcParser` 走
  /// `LrcParser.findTranslation(map, ms, 10)`(±10ms),`LrcParser` 走
  /// `translationMap[duration.inMilliseconds]`(精确查表,零容差)。而 lrc / tlyric
  /// 的小数位数由上传者决定(2 位 3 位都有),差 4ms 就让走 lrc 的歌**一个 key 都
  /// 查不到** —— 症状是"这一首有翻译、下一首没有"。
  ///
  /// 做法:不去猜精度,直接把 tlyric 落到 lrc 的时间轴上(主歌词本来就在 lrc 轴上),
  /// 两边落到同一批毫秒值,精确查表和 ±10ms 容差都能命中。
  ///
  /// 行 → 时间的对应:行数一致按行号一一对应(翻译逐行对应原文,比按时间猜可靠);
  /// 行数不一致退化成时间就近匹配([_translationToleranceMs] 内取最近的且未被占用
  /// 的)。宁可不配,也不能把翻译挂到错误的行上。
  String _alignTranslationToLrc(String? lrc, String tlyric) {
    if (lrc == null || lrc.trim().isEmpty) return tlyric;

    // lrc 侧:只要时间戳序列(谁在第几行不重要)
    final lrcStamps = <int>[];
    for (final l in _lyricLinesOf(lrc)) {
      final ms = l.ms;
      if (ms != null) lrcStamps.add(ms);
    }
    if (lrcStamps.isEmpty) return tlyric;

    // tlyric 侧:要行下标(回写时按位置替换)+ 时间戳(配对时用)。
    // 只要 lrc 时间轴上的行 —— ms 为 null 的是 yrc 逐字行,不在这条轴上。
    final tlyricLines = _lyricLinesOf(
      tlyric,
    ).where((e) => e.ms != null).toList();
    if (tlyricLines.isEmpty) return tlyric;

    final targets = _matchTranslationSlots(
      lrcStamps,
      tlyricLines.map((e) => e.ms!).toList(),
    );

    final out = tlyric.split('\n');
    // 从后往前替换,前面的替换才不会顶掉后面的下标
    for (var k = tlyricLines.length - 1; k >= 0; k--) {
      final idx = tlyricLines[k].index;
      final t = targets[k];
      if (t == null) {
        // 匹配不上 → 丢掉。留着它就可能按自己的时间去误挂到别的行上。
        out[idx] = '';
        continue;
      }
      final line = out[idx];
      var rewritten = line;
      for (final tag in _lrcTimeRe.allMatches(line).toList().reversed) {
        rewritten = rewritten.replaceRange(tag.start, tag.end, _formatLrcMs(t));
      }
      out[idx] = rewritten;
    }
    return out.where((l) => l.trim().isNotEmpty).join('\n');
  }

  /// 一次扫描,挑出 text 里所有**真正的歌词行**,返回 (行下标, 时间戳ms)。
  ///
  /// 判定行身份的唯一入口是 [_hasLyricLine](制作信息 JSON、纯标签行、空正文行都在
  /// 那里被排除),这样"哪些算歌词行"只有一份定义:[_realLyric](判空)和
  /// [_alignTranslationToLrc](配对)不会各说各话。
  ///
  /// ⚠️ 判空和配对必须共用这一套判据。之前配对只看"有没有时间戳",于是
  /// `[00:20.00]` 这种空行被当成一句翻译,凭空多占一个槽位,把真正能对上的翻译挤掉。
  ///
  /// **行下标**是必需的:回写时要按位置替换时间戳。yrc 逐字行返回 null 时间戳
  /// (它的时间在 `[start,dur]` 行头里,不是 lrc 时间轴),但仍算歌词行。
  List<({int index, int? ms})> _lyricLinesOf(String text) {
    final out = <({int index, int? ms})>[];
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (!_hasLyricLine(lines[i])) continue;
      out.add((index: i, ms: _timeStampOf(lines[i])));
    }
    return out;
  }

  /// 一行开头的 `[mm:ss.xx]` → ms;没有则 null。
  ///
  /// **只看行首**(firstMatch 而不是 hasMatch):lrc 允许一行多个时间戳
  /// (`[00:12.00][01:30.00]同一句`),但作为"这行属于第几句"的标识只需要第一个,
  /// 否则同一行会被当成两句、配对就乱了。
  int? _timeStampOf(String line) {
    final m = _lrcTimeRe.firstMatch(line);
    return m == null ? null : _lrcTimeMs(m);
  }

  /// tlyric 的小数是 2 位还是 3 位全看上传者,只要落进这个容差就还能配上。
  /// 250ms 是权衡:同一首歌 lrc/tlyric 的偏移正常远小于此,而相邻两行歌词通常
  /// 间隔 ≥500ms,不会认错行。
  static const _translationToleranceMs = 250;

  /// 给每个 tlyric 行决定"要落到的 lrc 时间"(null = 丢弃这一行)。
  List<int?> _matchTranslationSlots(List<int> lrcTimes, List<int> stamps) {
    // 行数一致 → 按行号一一对应
    if (lrcTimes.length == stamps.length) {
      return List<int?>.generate(stamps.length, (i) => lrcTimes[i]);
    }

    // 行数不一致 → 时间就近匹配,每个 lrc 时间只能被用一次
    final taken = <int>{};
    final out = List<int?>.filled(stamps.length, null);
    var cursor = 0; // 单调前进,不做全局回溯
    for (var i = 0; i < stamps.length; i++) {
      var best = -1;
      var bestDelta = _translationToleranceMs + 1;
      for (var k = cursor; k < lrcTimes.length; k++) {
        if (taken.contains(k)) continue;
        final delta = (lrcTimes[k] - stamps[i]).abs();
        if (delta < bestDelta) {
          bestDelta = delta;
          best = k;
        }
      }
      if (best >= 0 && bestDelta <= _translationToleranceMs) {
        taken.add(best);
        out[i] = lrcTimes[best];
        cursor = best;
      }
    }
    return out;
  }

  /// ms → `[mm:ss.SSS]`。flutter_lyric 的 LrcParser 小数不足 3 位会右侧补 0,
  /// 所以这里固定写 3 位,解析回来是同一个毫秒值。
  String _formatLrcMs(int ms) {
    final m = ms ~/ 60000;
    final s = (ms % 60000) ~/ 1000;
    final cs = ms % 1000;
    return '[${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}.'
        '${cs.toString().padLeft(3, '0')}]';
  }

  /// 主歌词选 yrc 还是 lrc,都没有就显示"暂无歌词"。
  ///
  /// **不能用 `??` 判空**:[LyricsRepository] 把上游缺失的字段规范成 **空字符串**
  /// (`(r.body['yrc']?['lyric'])?.toString() ?? ''`),不是 null。而 Dart 里
  /// `'' ?? fallback` **返回空字符串本身**,于是 `loadLyric('')` →
  /// flutter_lyric 四个 parser 全部 isMatch 失败 → FallbackParser 返回空
  /// LyricModel → 界面一片空白,明明 lrc 里有词。
  String _mainLyric(Lyrics aligned) =>
      _realLyric(aligned.yrc) ?? _realLyric(aligned.lrc) ?? _noLyricPlaceholder;

  /// "没有歌词"占位。
  ///
  /// **必须带 `[00:00.00]` 时间戳**:flutter_lyric 是按行首时间戳选 parser 的,
  /// 裸字符串("暂无歌词")四个 parser 全不匹配 → FallbackParser → 空模型 →
  /// 界面还是空白(实测),等于白给。带时间戳才会被 LrcParser 解析成一行。
  static const _noLyricPlaceholder = '[00:00.00]暂无歌词';

  /// 空字符串 → null。给 flutter_lyric 的可选参数用(空串会走一遍无意义的解析)。
  String? _nonBlank(String? s) => (s == null || s.trim().isEmpty) ? null : s;

  /// 空字符串 / **只有元信息没有歌词** → null。
  ///
  /// 后者是真实存在的坑:没有歌词的曲子,网易云仍然会返回
  /// `{"t":-1,"c":[{"tx":"作词: "},...]}` 这种内容 —— 字符串**非空**(_nonBlank 会
  /// 放行)但一行歌词都没有,喂给 flutter_lyric 时四个 parser 全不匹配 → 走
  /// FallbackParser → 空模型 → 界面空白,用户看到的是"没歌词"而不是明确提示。
  ///
  /// 所以判空要多一层:**必须含有真正的歌词行**(lrc 行头带正文 / yrc 逐字行)。
  ///
  /// 另:元信息和真逐字歌词**共存**时(大多数正常歌曲),`YrcParser` 会把
  /// `{"t":0,"c":[...]}` 当成歌词行渲染(`start = 0ms`),界面凭空多一行"作词: xxx"。
  /// _realLyric 管不了这个(它只判"有没有歌词"),要根治得在喂进去之前剥掉 JSON 行。
  String? _realLyric(String? text) {
    final t = _nonBlank(text);
    if (t == null) return null;
    return _lyricLinesOf(t).isNotEmpty ? t : null;
  }

  /// 这一行是不是"真正的歌词行"。排除制作信息 JSON(`{"t":..,"c":[..]}`)、
  /// 纯标签行(`[ti:..]`)和空正文行。
  static bool _hasLyricLine(String line) {
    final s = line.trim();
    if (s.isEmpty) return false;
    if (s.startsWith('{')) return false;
    // lrc:有时间戳 且 去掉时间戳后还剩正文。要 replaceAll(而不是只去行首那个):
    // `[00:12.00][01:30.00]同一句` 第二个时间戳会被误当成正文。
    if (_lrcTimeRe.hasMatch(s)) {
      if (s.replaceAll(_lrcTimeRe, '').trim().isNotEmpty) return true;
    }
    // yrc 逐字行:行头之后必须有音节。body **全部**由音节组成,所以判据是
    // "有没有音节"而不是"去掉音节后还剩字" —— 后者恒为空,会误杀所有逐字行。
    final header = _yrcHeaderRe.firstMatch(s);
    if (header != null) {
      return _yrcWordRe.hasMatch(s.substring(header.end));
    }
    return false;
  }
}

/// yrc 逐字行里的一个 `(start,duration,zero)字` 片段。[start] / [end] 是它在
/// 行内 body 字符串中的偏移,回写时用来保留逐字匹配覆盖不到的杂字符。
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
