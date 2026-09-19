<img src="https://cmach.ccwu.cc/oceanus.png" alt="说明" width="20%">

# Oceanus 


一个 Flutter 网易云音乐客户端,

底层NodeJs Bridge 由 [ncm_api_enhanced](https://github.com/cmachsocket/ncm_api_enhanced) 自行维护,提供异步 API 给 Flutter 调用。

## 特色

- Flutter 原生跨平台 ，多端统一运行

- 原生 UI , 兼顾性能与体验

- 仅音乐功能，去除广告、社区、视频、直播等非音乐功能

- 0 硬编码UI,适配多种屏幕尺寸，支持横竖屏切换

## 功能

- 搜索 / 歌单 / 专辑 / 艺人 / 我的收藏
- 后台播放 + 锁屏 / 通知栏控制(基于 `audio_service` + `just_audio`)，音质选择
- 同步歌词(基于 `flutter_lyric`)
- 收藏的歌曲 / 专辑 / 艺人 / 歌单
- 亮 / 暗主题 ， 强调色选择
- 下载功能
- 状态栏歌词（在41831端口暴露相关歌词）

## 构建运行

```bash
flutter pub get
flutter run                  
flutter analyze
```
windows版本会自带 nodejs, linux/mac 需要自行安装 nodejs

安卓上js解释器为bare

## MAC 构建

因为并没有mac设备，所以mac构建仅在github action通过，未在本地测试过。

欢迎有mac设备的朋友帮忙测试。

## 说明

本项目为个人兴趣开发，非商业用途，禁止用于商业用途。

如侵权，请联系我删除。