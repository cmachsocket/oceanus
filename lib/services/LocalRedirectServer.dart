import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:get/get.dart';

import 'repositories/SongRepository.dart';

/// 本机 302 定向 server:让 just_audio 拿到的播放地址**永不过期**。
///
/// 网易云 `/song/url/v1` 给的是**临时直链**(约 20 分钟失效),提前解析存进队列
/// 排到队尾就起不来。所以队列里只放一个稳定地址
/// `http://127.0.0.1:<port>/s/<songId>/<file>?q=<level>`(token 就是 songId,
/// server 完全无状态,不用注册不用清理),真正 prepare 那一刻才查一次真地址
/// 再 302 过去。音频数据仍由 mpv / AVPlayer 原生去 CDN 拉,本 server 只多花
/// 一次 RTT,不碰字节流(所以不用处理 Range / 206 / 流式转发)。
///
/// 这也是 Dart 层唯一能拦到"原生播放器真实请求"的地方 —— mpv / ExoPlayer 的
/// socket 不经过 Dart VM,HttpClient / HttpOverrides / Dio 全都看不见。
///
/// [init] 起不来时 [enabled] 保持 false,播放链路退回直连真地址,server 只是
/// 可选加速层不是单点。
///
/// **平台前置配置(缺了就连不上)**:
/// - Android `minSdk = 31`,API 37 以下 loopback 的 cleartext 默认被拦(官方只对
///   API 37+ 隐式放行)。需 `res/xml/network_security_config.xml` 只对
///   127.0.0.1 / localhost 放行 + manifest 挂 `android:networkSecurityConfig`。
///   (mpv 是原生 C 层本来不受它管,但 ExoPlayer 回退路径走 HttpURLConnection。)
/// - iOS ATS 要开 `NSAllowsLocalNetworking`。
/// - Web:`dart:io` 不存在,本 service 不启用([enabled] 恒 false)。
/// - mpv:`JustAudioMediaKit.protocolWhitelist` 必须含 `ytdl`,否则 mpv 会把
///   非 IP 主机名丢给 yt-dlp 解析而失败(地址已用 127.0.0.1 规避,这是双保险)。
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

  // mpv 打开一个 http 源会连打两三次请求(探测 + Range),重复打 /song/url/v1
  // 既浪费也容易撞上游限流。60s 对"URL 有 20 分钟寿命"来说足够新鲜。
  static const _ttl = Duration(seconds: 60);
  final Map<String, ({String url, DateTime at})> _memo = {};

  /// in-flight 的解析请求(key 同 [memo]),用于并发去重
  final Map<String, Future<String?>> _pending = {};

  /// 队列 / just_audio 侧拿到的稳定地址。[quality] 决定 URL 上的 `?q=`(解析
  /// 真地址时按同一个 level 取)和本机路径的扩展名(只给 mpv 猜 demuxer,真正的
  /// 文件名以 302 目标为准)。
  ///
  /// 只在 [enabled] 为 true 时调用 —— 端口是随机分配的。
  Uri urlFor({required String songId, required String quality}) {
    assert(enabled, 'urlFor 只能在 server 起来后调用 (先看 LocalRedirectServer.enabled)');
    final level = quality.isEmpty ? 'standard' : quality;
    return Uri.http(
      // 端口必须写进 authority:Uri.http 的 port 默认 80,漏掉会连到 80 端口
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
      Get.log('LocalRedirectServer: web 不支持 dart:io,已禁用');
      return this;
    }
    try {
      // bind 放宽到 anyIPv4:地址对外用 127.0.0.1,但某些设备/模拟器上
      // loopbackIPv4 解析不到
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _server!.idleTimeout = const Duration(seconds: 30);
      _server!.autoCompress = false; // 音频不需要 gzip,开了白烧 CPU
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
      // 回 404,播放器的 errorStream 会收到并转成 loadError 状态
      Get.log('LocalRedirectServer: 取不到 $songId 的播放地址,404');
      await _replyNotFound(req);
      return;
    }

    // 唯一的拦截点:想换 CDN / 加参数 / 选镜像,改 [_rewrite] 即可。
    final target = Uri.parse(_rewrite(url));

    Get.log('LocalRedirectServer: 302 ${segs.last} -> $target');
    req.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    // 302(movedTemporarily)而不是 307:GET/HEAD 没有 body,直接给新地址最省事
    await req.response.redirect(target, status: HttpStatus.movedTemporarily);
  }

  /// 真实 CDN 地址的改写点(默认原样返回)
  String _rewrite(String url) => url;

  Future<String?> _resolve(String songId, String? quality) async {
    final key = '$songId@${quality ?? ''}';
    final hit = _memo[key];
    if (hit != null && DateTime.now().difference(hit.at) < _ttl) return hit.url;

    // in-flight 去重:memo 只挡"已完成"的,这里挡"正在飞"的
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
      if (_memo.length > 32) _memo.clear(); // 长列表播放时别把 map 撑大
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
