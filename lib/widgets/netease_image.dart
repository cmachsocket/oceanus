import 'dart:io';
import 'package:cached_network_image_ce/cached_network_image.dart';
import '../models/headers.dart';

/// 工厂:把 URL 包成带 [NeteaseImageHeaders.neteaseImageHeaders] 的
/// `NetworkImage`,给 `CircleAvatar.backgroundImage` 这类要 ImageProvider 的地方用。
///
/// 需要 UA 头是因为 `*.music.126.net` 把 Dart 默认 UA(`Dart/x.x (dart:io)`)
/// 拉黑回 403。
CachedNetworkImageProvider neteaseNetworkImage(String url) =>
    CachedNetworkImageProvider(
      url,
      headers: NeteaseImageHeaders.neteaseImageHeaders,
    );

/// **全局** UA override。`Image.network` 的 `headers` 参数在 Android 上不稳定
/// (底层 image resource service 可能忽略),所以在 main 里装
/// `HttpOverrides.global`,让所有 HttpClient 都被塞上 UA。
///
/// 不影响音频与 SDK:那些请求走原生网络栈,不经过 dart:io HttpClient。
class NeteaseHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    // dart:io 会自动把 userAgent 塞进每个请求的 User-Agent 头
    client.userAgent = NeteaseImageHeaders.neteaseImageHeaders['User-Agent']!;
    return client;
  }
}
