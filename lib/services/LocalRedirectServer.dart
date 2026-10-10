import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get/get.dart';

import 'repositories/SongRepository.dart';

/// 本机 302 定向 server —— 让 just_audio 拿到的播放地址**永不过期**
///
/// ## 为什么需要它
///
/// 网易云 `/song/url/v1` 返回的是**临时直链**(约 20 分钟失效)。只要播放地址
/// 被提前解析出来存进队列,排到队尾时就可能已经过期 → 那一首直接起不来。
/// 反过来,如果每次 prepare 都重新解析,又会把 URL 解析和播放状态机死死绑在
/// handler 里(现在就是 [_playAt] 每次切歌都 await `fetchSongUrl`)。
///
/// 这里把两件事拆开:
/// - **队列 / just_audio 侧**:只拿一个稳定地址
///   `http://localhost:<port>/s/<songId>/<file>?q=<level>`,token 就是 songId,
///   所以 server 完全**无状态** —— 不用注册、不用清理,队列重建 / shuffle
///   重排 / 切歌都不会指向一个不存在的条目。
/// - **真 URL 侧**:在收到请求那一刻(即播放器真正 prepare 的瞬间)才去
///   `/song/url/v1` 换一条新的,然后 `302` 把播放器**定向**到真实 CDN 地址。
///   音频数据本身仍然由 mpv / AVPlayer 原生去 CDN 拉,本 server 只多花一次 RTT,
///   不碰字节流(所以不用处理 Range / 206 / 流式转发)。
///
/// 这也是 Dart 层唯一能拦到"原生播放器真实请求"的位置 —— mpv / ExoPlayer 的
/// socket 不经过 Dart VM,`dart:io` 的 HttpClient、HttpOverrides、Dio 全都看不见。
///
/// ## 降级
///
/// 端口被占 / 非 web 以外的环境起不来时,[init] 吞掉异常并让 [enabled] 保持
/// false,播放链路会自动退回"直连真实 URL"(见 AudioPlayerHandler._playAt),
/// 即行为跟引入本 server 之前完全一致 —— server 永远是可选加速层,不是单点。
///
/// ## 平台前置配置(缺了就连不上,必须先改)
///
/// - **Android**: `minSdk = 31`,API 37 以下 localhost 的 cleartext 是默认被拦的
///   (官方只对 API 37+ 给 loopback 隐式放行)。需要
///   `android/app/src/main/res/xml/network_security_config.xml` 里只对
///   localhost / 127.0.0.1 放行,manifest 上挂 `android:networkSecurityConfig`。
/// - **iOS**: 必须写 `localhost` 而不是 `127.0.0.1` —— 后者是 IP 字面量,
///   iOS 17+ / macOS 14+ 的 ATS 默认不再放行。Info.plist 里开
///   `NSAllowsLocalNetworking`。
/// - **Web**: `dart:io` 在 web 上不存在,本 service 直接不启用([enabled] 恒 false)。
class LocalRedirectServer extends GetxService {
  LocalRedirectServer(this._songRepo, {this.port = 0});

  final SongRepository _songRepo;

  /// 监听端口。0 = 由系统分配随机端口,免得跟别的服务撞固定端口。
  final int port;

  HttpServer? _server;

  /// server 是否真的起来了。false = 播放链路走直连降级。
  bool get enabled => _server != null;

  /// 本机地址。**必须用 localhost 而不是 127.0.0.1**(见类注释的平台配置)。
  String get baseUrl => 'http://localhost:${_server!.port}';

  // ---- URL 解析结果短 TTL 记忆 ------------------------------------------------
  //
  // mpv 打开一个 http 源时可能连打两三次请求(探测 + Range),同一首歌短时间
  // 内重复打 /song/url/v1 既浪费也更容易撞上游限流。60s TTL 对"URL 有 20 分钟
  // 寿命"来说足够新,同时也让"排到队尾才播"的那一首拿到的是当下新鲜的地址。

  static const _ttl = Duration(seconds: 60);
  final Map<String, ({String url, DateTime at})> _memo = {};

  /// in-flight 的解析请求(key 同 [memo]),用于并发去重
  final Map<String, Future<String?>> _pending = {};

  /// 队列 / just_audio 侧拿到的稳定地址。
  ///
  /// [quality] 是音质 level 字符串(standard/higher/exhigh/lossless/hires),
  /// 决定两件事:URL 上带的 `?q=`(server 解析真地址时要按同一个 level 取),
  /// 以及本机路径的扩展名(给 mpv 猜 demuxer 用;真正的 302 目标是 CDN 上的
  /// 真实文件名,扩展名以那个为准)。
  ///
  /// 只在 [enabled] 为 true 时调用 —— 端口是随机分配的,没有 server 就没有端口。
  Uri urlFor({required String songId, required String quality}) {
    assert(enabled, 'urlFor 只能在 server 起来后调用 (先看 LocalRedirectServer.enabled)');
    final level = quality.isEmpty ? 'standard' : quality;
    return Uri.http(
      // 端口必须写进 authority:Uri.http 的 port 默认 80,漏掉的话
      // 播放器会去连 80 端口而不是 server 的随机端口
      'localhost:${_server!.port}',
      '/s/$songId/$songId.${_extOf(level)}',
      {'q': level},
    );
  }

  static String _extOf(String level) =>
      (level == 'lossless' || level == 'hires') ? 'flac' : 'mp3';

  /// 起 server。**不抛** —— 起不来就保持 [enabled] == false,上层走直连降级。
  Future<LocalRedirectServer> init() async {
    if (kIsWeb) {
      // dart:io 在 web 上不可用,这里根本不会被编译进来;
      // 保留判断是为了让 enabled 的语义在所有平台一致。
      Get.log('LocalRedirectServer: web 平台不支持 dart:io,已禁用');
      return this;
    }
    try {
      // loopback 而不是 InternetAddress.anyIPv4:只给本机用,不暴露到局域网
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      _server!.idleTimeout = const Duration(seconds: 30);
      // 音频不做 gzip,开了白烧 CPU 还容易让某些客户端等 Content-Encoding
      _server!.autoCompress = false;
      _server!.listen(
        _onRequest,
        onError: (Object e) {
          Get.log('LocalRedirectServer: accept 异常 $e');
        },
      );
      Get.log('LocalRedirectServer: 已监听 $baseUrl');
    } catch (e) {
      _server = null;
      Get.log('LocalRedirectServer: 启动失败($e),播放退回直连真实 URL');
    }
    return this;
  }

  Future<void> _onRequest(HttpRequest req) async {
    final segs = req.uri.pathSegments;
    // 路径形态:/s/<songId>/<任意文件名> —— 文件名只给 mpv 看,不参与匹配。
    final songId = (segs.length >= 2 && segs[0] == 's') ? segs[1] : null;
    if (songId == null) {
      await _replyNotFound(req);
      return;
    }

    final url = await _resolve(songId, req.uri.queryParameters['q']);
    if (url == null) {
      // 取不到地址 → 回 404,让播放器的 errorStream 报错,
      // 由 AudioPlayerHandler 转成既有的 loadError / 错误 playbackState 路径。
      Get.log('LocalRedirectServer: 取不到 $songId 的播放地址,404');
      await _replyNotFound(req);
      return;
    }

    // ★ 唯一的拦截点。想换 CDN / 加参数 / 选镜像,改这一行即可。
    final target = Uri.parse(_rewrite(url));

    // 播放器只 prepare 时打这一次,之后的 Range 请求由它自己直奔 CDN。
    Get.log('LocalRedirectServer: 302 ${segs.last} -> $target');
    req.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    // 302(movedTemporarily)而不是 307:GET/HEAD 没有 body,直接给新地址最省事
    await req.response.redirect(target, status: HttpStatus.movedTemporarily);
  }

  /// 真实 CDN 地址的唯一改写点(默认原样返回)。
  String _rewrite(String url) => url;

  Future<String?> _resolve(String songId, String? quality) async {
    final key = '$songId@${quality ?? ''}';
    final hit = _memo[key];
    if (hit != null && DateTime.now().difference(hit.at) < _ttl) return hit.url;

    // in-flight 去重:mpv 打开一个源可能同时打出多个请求(探测 + 预读),
    // 上面的 memo 只挡"已完成"的,这里挡"正在飞"的 —— 否则弱网下同一秒
    // 能打出去好几个 /song/url/v1,既浪费也更容易撞上游限流。
    final flying = _pending[key];
    if (flying != null) return flying;

    final fut = _songRepo.fetchSongUrl(songId, level: quality);
    _pending[key] = fut;
    try {
      final url = await fut;
      if (url == null) {
        _memo.remove(key);
        return null;
      }
      // 只留最近的一小撮,避免长列表播放把 map 撑大
      if (_memo.length > 32) _memo.clear();
      _memo[key] = (url: url, at: DateTime.now());
      return url;
    } finally {
      _pending.remove(key);
    }
  }

  Future<void> _replyNotFound(HttpRequest req) async {
    req.response.statusCode = HttpStatus.notFound;
    req.response.headers.contentType = ContentType.text;
    req.response.write('no playable url');
    await req.response.close();
  }

  @override
  void onClose() {
    _server?.close(force: true);
    _server = null;
    _memo.clear();
    _pending.clear();
    super.onClose();
  }
}
