# 网易云 API 接入文档(ncm_api_enhanced)

> Oceanus 使用 [ncm_api_enhanced](https://github.com/cmachsocket/ncm_api_enhanced) 作为网易云音乐 API 方案:
> 内嵌 Node.js 运行时 + 上游 `@neteasecloudmusicapienhanced/api`(439 个 module 函数)。
>
> 本文覆盖**本项目实际怎么用**:架构、`NeteaseApi` facade、参数映射、cookie/登录、错误处理、仓库层接入点。
> 上游完整接口目录见 [附录 A](#附录-a上游完整接口目录439)。

---

## 目录

1. [架构总览](#1-架构总览)
2. [安装与初始化](#2-安装与初始化)
3. [响应结构](#3-响应结构)
4. [调用方式](#4-调用方式)
5. [Cookie 与登录](#5-cookie-与登录)
6. [已接入的接口](#6-已接入的接口)
7. [错误处理](#7-错误处理)
8. [仓库层与接入点](#8-仓库层与接入点)
9. [注意事项](#9-注意事项)
10. [附录 A:上游完整接口目录](#附录-a上游完整接口目录439)
11. [附录 B:枚举速查](#附录-b枚举速查)

---

## 1. 架构总览

```
UI (GetX Controller)
   ↓
app/data/repositories/*.dart          ← 唯一调 API 的地方
   ↓
NeteaseApi.callApi(method, [位置参数])  ← lib/sdk/netease_api.dart
   ↓  positionalToQuery()               ← lib/sdk/method_spec.dart
NcmApi.call(method, query)             ← ncm_api_enhanced 包
   ↓  NDJSON over stdin/stdout
内嵌 node / libnode.so → bridge.js → 上游 module 函数 → music.163.com
```

关键点:

- **没有 worker isolate,也没有 HTTP 层**。bridge 本身就是异步的,不需要再套一层。
- **cookie 状态直接活在主 isolate**,由 `NeteaseApi` 持有(内存 + GetStorage 持久化)。
- 上游 module 函数只吃一个 `Map<String, dynamic>`,key 就是 HTTP query 字段名。

### 平台支持

| 平台 | 运行时 | 传输 |
| --- | --- | --- |
| Linux / macOS | 系统 `node`(≥18) | NDJSON over stdin/stdout |
| Windows | 随包附带 `node.exe` | NDJSON over stdin/stdout |
| Android | 内嵌 `libnode.so`(仅 arm64-v8a) | `dart:ffi` ↔ `libncm_node_bridge.so` |
| iOS | 未实现 | — |

---

## 2. 安装与初始化

`pubspec.yaml`:

```yaml
dependencies:
  ncm_api_enhanced:
```

### 启动顺序

`lib/main.dart` 里 **必须** 在 `GetStorage.init()` 之后初始化 —— `NeteaseApi.init()` 要读持久化的 cookie 和登录标记:

```dart
await GetStorage.init();
await initNeteaseApi();   // 创建 facade + 启动 NcmApi + 灌回 cookie
```

`initNeteaseApi()`(`lib/sdk/netease_api.dart`)做三件事:

1. `Get.put<NeteaseApi>(NeteaseApi(), permanent: true)`
2. `await _ncm.start()` —— 拉起 node 进程 / 初始化 libnode
3. 从 GetStorage 恢复 cookie;若**未登录且没有匿名 cookie**,顺手拉一次游客 cookie

之后各处用 `Get.find<NeteaseApi>()` 拿实例。

### 退出

node 子进程必须显式关闭,否则 Flutter 先退出会留下孤儿进程。
`lib/app/services/app_shutdown.dart` 负责统一收尾(幂等,5s 兜底超时,每步 best-effort):

```
audio → netease-api(node bridge) → redirect-server → lyrics-server → tray
```

触发点:
- 托盘"退出"菜单 / 窗口关闭 → `lib/app/services/tray_controller.dart`
- macOS Cmd+Q / 桌面会话登出 → `lib/main.dart` 的 `AppLifecycleListener(onExitRequested:)`

`NeteaseApi.shutdown()` 本身幂等(`_shutdownFuture ??=`),`onClose()` 里兜底再调一次。

---

## 3. 响应结构

### 上游原始形状

`NcmApi.call()` 返回的是上游 `Response`:

```dart
{
  'status': 200,                          // HTTP status
  'body': {'code': 200, ...},             // 业务 JSON
  'cookie': ['MUSIC_U=xxx; Path=/; ...'], // 多条 Set-Cookie
}
```

### 本项目适配层

`lib/sdk/music_response.dart` 把它转成 app 内部统一的 `MusicResponse`:

```dart
class MusicResponse {
  final int status;                    // 正常恒为 200
  final Map<String, dynamic> body;     // 业务 JSON
  final Map<String, String> headers;   // 只会填 'Set-Cookie'
  String get cookies;                  // headers['Set-Cookie']
  Map<String, dynamic> get data;       // == body
}
```

`cookie` 是 list,适配层用 `', '` 连成一条塞进 `headers['Set-Cookie']`。

### 业务成功判定

`lib/sdk/api_call.dart` 的 `checkResponse()`:

- `status != 200` → 失败
- `body['code']` 存在且 `!= 200` → 失败
  - 两层 body 都要查:`/playlist/tracks` 之类的端点 code 在 `body['body']['code']`
- `code` 缺失是允许的(部分 `banner` / `setting` 没有),此时只看 HTTP status

---

## 4. 调用方式

### 4.1 走 facade(推荐,项目里的唯一姿势)

`NeteaseApi.callApi(method, [位置参数])` —— 第一个参数是上游 module 名,第二个是**位置参数列表**,由 `method_spec.dart` 翻成 query dict:

```dart
final r = await apiCall(
  () => _api.callApi('playlist_detail', <Object?>[playlistId]),
  what: '歌单详情',
);
final tracks = r.body['playlist']['tracks'] as List;
```

`method_spec.dart` 里的映射表长这样:

```dart
MethodSpec(
  method: 'playlist_track_all',
  params: [ParamSlot('id'), ParamSlot('limit'), ParamSlot('offset')],
),
```

`ParamSlot` 三个字段:

| 字段 | 含义 |
| --- | --- |
| `field` | 上游 query 字段名(snake_case,与上游 `interface.d.ts` 一致) |
| `defaultIfMissing` | 参数缺省时填的默认值;没给则传 `null` |
| `dropIfNull` | `true` 时参数为 null 就整个省略(有些端点不接受显式 null) |

**加新接口**:往 `methodSpecs` 里追加一条,然后 `callApi` 就能用了。
没登记的方法名会抛 `ArgumentError`(查表失败),不会静默发一个空请求。

### 4.2 直接调包(仅在 facade 不便时)

`NcmApi.call()` 直接吃 query dict,不做位置参数翻译:

```dart
final raw = await NcmApi().call('album', {'id': 12345});
```

**注意**:直接调包会**绕过 cookie 注入**。`NeteaseApi._callRaw` 负责把身份 cookie 塞进 query,绕过去所有请求都是匿名身份。

### 4.3 动态方法(不推荐)

`NcmApi` 重写了 `noSuchMethod`,`api.album({'id': 12345})` 这种写法在**运行时**能work:

```dart
final r = await api.album({'id': 12345});
```

但:

- **analyzer 看不见**,IDE 会报 "method not defined";
- 当前解析到的版本(0.2.2)对**具名参数**的处理有 bug —— 具名参数的 key 会变成 `Symbol("id")` 而不是 `id`,只有**单个位置 map 参数**是对的。

项目里统一用 `api.call(...)` / `NeteaseApi.callApi(...)`,不要用动态方法。

---

## 5. Cookie 与登录

### 5.1 注入机制

上游 `util/option.js` 优先读 `query.cookie`(JSON 对象或 `k=v; k=v` 字符串),其次才回落到 `NETEASE_COOKIE` 环境变量。

`NeteaseApi._callRaw` 在每次调用时自动注入:

```
调用方自己传的 cookie  >  登录 cookie(_authCookie)  >  匿名 cookie(_anonCookie)  >  空
```

调用方想屏蔽 cookie 就自己传 `cookie: ''`。

**不注入会怎样**:所有请求都是匿名身份 —— `user_account` 返 null,Library 相关接口 301。

### 5.2 cookie 解析

`NeteaseApi.parseCookieString()` 把 `Set-Cookie` 字符串拆成 map:

- 按 `,` 再按 `;` 切
- 去掉 key 前后非法字符
- **只保留首字符不是小写字母的 key** —— `MUSIC_U` / `__csrf` / `NMTID` / `NMSCVT` 保留,小写字母开头的丢弃
- 显式跳过 `Path` / `Expires` / `HttpOnly` / `SameSite` / `Max-Age` / `Domain` / `Secure`

另外 `/register/anonimous` 之类的接口会把 cookie 放在 `body.cookie` 里,`_mergeBodyCookies()` 会把它也并进来(取并集)。

### 5.3 持久化

GetStorage default box:

| key | 类型 | 含义 |
| --- | --- | --- |
| `netease_logged_in_v1` | bool | 登录标记 |
| `netease_cookie_v1` | `Map<String, String>` | 身份 cookie |
| `netease_anon_cookie_v1` | `Map<String, String>` | 游客 cookie |
| `netease_uid_v1` | int | 当前用户 uid |

### 5.4 登录流程

当前**只实现了手机验证码登录**(`lib/sdk/auth_controller.dart`):

```
1. applyAnonymousCookie()      先建访客 session(NMTID/NMSCVT)
                                让后端把这次请求当成"已有会话的设备",
                                避开裸 IP 直连触发云盾 10004 + phoneReuse 重定向
2. sendCaptcha()               → captcha_sent
3. loginCellphone()            → login_cellphone
4. applyLoginCookie(r)         解析 Set-Cookie 并持久化
5. loadAuthInfo()              拉 user_account 拿 uid
```

**成功判定 = cookie 非空,不是响应 code。**
业务 code 200 但 cookie 缺失,基本就是被云盾拦了 / 风控重定向。

UI 层(`lib/app/modules/settings/controllers/login_controller.dart`)只管手机号 / 验证码格式校验、60s 倒计时、snackbar,不碰 SDK。

### 5.5 游客 cookie

`NeteaseApi.init()` 在"未登录且没有匿名 cookie"时拉一次 `/register/anonimous`。
`AuthController.login()` 也会在发登录请求前再拉一次。

拉失败只打日志,**不阻断启动**。

### 5.6 登出

`NeteaseApi.logout()` 清内存里的 `_authCookie`,删 `netease_cookie_v1` / `netease_anon_cookie_v1`,把 `netease_logged_in_v1` 置 false。

---

## 6. 已接入的接口

`lib/sdk/method_spec.dart` 当前登记 **28 条**。以下是位置参数顺序(可直接照抄调用):

### 登录与用户

| 方法 | 位置参数 | 用途 |
| --- | --- | --- |
| `captcha_sent` | `phone`, `ctcode` | 发验证码(ctcode 默认 `86`) |
| `login_cellphone` | `phone`, `captcha`, `countrycode` | 验证码登录(countrycode 默认 `86`) |
| `register_anonimous` | — | 拉游客 cookie |
| `user_account` | — | 当前用户信息(取 uid) |
| `login_status` | — | 登录状态 |

### 歌单相关

| 方法 | 位置参数 |
| --- | --- |
| `playlist_detail` | `id` |
| `playlist_track_all` | `id`, `limit`, `offset` |
| `playlist_create` | `name`, `privacy`, `type` |
| `playlist_tracks` | `op`(`add`/`del`), `pid`, `tracks` |
| `playlist_delete` | `id` |
| `playlist_subscribe` | `t`(`1` 收藏 / `2` 取消), `id` |

### 专辑与艺人

| 方法 | 位置参数 |
| --- | --- |
| `album` | `id` |
| `album_sublist` | `limit`(默认 `50`) |
| `album_sub` | `id`, `t`(`1` 收藏 / 其他取消) |
| `artists` | `id` |
| `artist_sublist` | — |
| `artist_sub` | `id`, `t` |
| `artist_album` | `id` |
| `artist_songs` | `id`, `limit`(默认 `50`) |

### 歌曲与歌词

| 方法 | 位置参数 |
| --- | --- |
| `song_url_v1` | `id`(逗号分隔), `level` |
| `song_detail` | `ids`(逗号分隔) |
| `like` | `id`, `like` |
| `likelist` | `uid` |
| `lyric_new` | `id` |

### 搜索与推荐

| 方法 | 位置参数 |
| --- | --- |
| `search` | `keywords`, `type`(默认 `1`), `limit`(默认 `30`) |
| `personalized` | `limit`(默认 `30`) |
| `user_playlist` | `uid`, `limit`(默认 `50`) |
| `user_follow_mixed` | `size`(默认 `50`), `cursor`(默认 `0`), `scene`(默认 `1`) |

---

## 7. 错误处理

### 7.1 三类失败

| 失败类型 | 表现 | 抛出 |
| --- | --- | --- |
| 业务错误 | `body.code != 200` | **不抛**,正常返回 |
| bridge 错误 | node 进程死了 / IPC 断了 / JSON 解析失败 | `BridgeError` |
| 超时 | 超过 `kDefaultCallTimeout`(30s) | `TimeoutException` |
| 方法名写错 | 不在 `_methodNames` 白名单 | `ArgumentError`(同步抛) |
| bridge 没启动就调 | — | `StateError` |

### 7.2 统一包装

`apiCall()` 把上面这些**全部**包成 `ApiException`:

```dart
Future<MusicResponse> apiCall(
  Future<MusicResponse> Function() fn, {
  String? what,
}) async {
  try {
    final r = await fn();
    checkResponse(r, hint: what);
    return r;
  } on ApiException {
    rethrow;
  } catch (e) {
    throw ApiException(
      ApiException.localUnexpected,   // code = -99
      '${what ?? "API"} 调用失败: $e',
      cause: e,
    );
  }
}
```

`ApiException`(`lib/app/data/models/api_exception.dart`):

| 常量 | code | 含义 |
| --- | --- | --- |
| `localNetwork` | `-1` | 网络不可达 |
| `localParse` | `-2` | 响应解析失败 |
| `localUnexpected` | `-99` | 其他未分类异常(bridge 错误 / 超时都落这里) |
| — | 业务 code | 直接用上游 `body.code` |

### 7.3 仓库层的处理惯例

**读接口**:catch `ApiException` → 返回 `null` / 空集合,不打断 UI。

```dart
} on ApiException {
  return const {};
}
```

**写接口**(收藏 / 取消收藏):catch 后 `rethrow` 或返回 `false`,让 UI 能提示用户。

`AuthController` 用裸 `catch (_)` 全兜 —— 非 `ApiException`(平台异常 / 解析失败)也得让 UI 收到失败反馈,而不是冒泡。

---

## 8. 仓库层与接入点

### 8.1 目录

```
lib/sdk/
  netease_api.dart      NeteaseApi facade(持有 NcmApi + cookie)
  method_spec.dart      方法 → 位置参数映射表
  music_response.dart   上游 Response → MusicResponse
  api_call.dart         apiCall() + checkResponse()
  auth_controller.dart  登录凭证全局持有者
lib/app/data/repositories/
  song_repository.dart      song_url_v1 / song_detail
  playlist_repository.dart  playlist_detail / playlist_track_all / playlist_create
                           playlist_tracks / playlist_delete
  album_repository.dart     album
  artist_repository.dart    artists / artist_album / artist_songs
  search_repository.dart    search
  library_repository.dart   personalized / user_playlist / album_sublist
                           user_follow_mixed
  liked_repository.dart     album_sublist / album_sub / user_playlist
                           playlist_subscribe / likelist / like
                           artist_sublist / artist_sub / artists
  lyrics_repository.dart    lyric_new
```

**规则:UI / Controller 不直接调 API**,一律走 repository。

### 8.2 加一个新接口的完整步骤

1. `lib/sdk/method_spec.dart` → 追加 `MethodSpec`
2. `lib/app/data/repositories/xxx_repository.dart` → 加方法,内部 `_api.callApi(...)`
3. 需要新响应模型 → `lib/app/data/models/xxx.dart` 加 `Xxx.fromNeteaseJson`
4. `flutter analyze` + `flutter test`

### 8.3 响应解析约定

模型用 `Xxx.fromNeteaseJson(Map<String, dynamic>)` 工厂,兼容上游新旧两种字段名:

| 模型 | 兼容的字段 |
| --- | --- |
| `Song` | `name`→title、`ar`/`artists`→artist、`al`/`album`→album/picUrl、`dt`/`duration`(ms) |
| `Artist` | `briefDesc`/`desc`→bio、`picUrl`→photoUrl、`musicSize`→songCount、`albumSize`→albumCount、`fans`→fanCount |
| `Album` | `artists[0].name`→artist、`picUrl`→coverUrl、`size`→songCount、`publishTime`(ms)→releaseDate、`type`→`AlbumType` |

位置: `lib/app/data/models/song.dart`、`lib/app/data/models/artist.dart`、`lib/app/data/models/album.dart`、`lib/app/data/models/library_summary.dart`。

---

## 9. 注意事项

### 9.1 风控

- **不要频繁调登录接口**(被风控会要求扫码验证)
- **`scrobble`(听歌打卡)别刷,封号**
- `personal_fm` 单次最多给一首,后端会限流
- 登录前先建访客 session 可以显著降低触发云盾的概率(见 §5.4)

### 9.2 网易云盾

2024 年起密码登录大量触发云盾验证。优先用:

- 验证码登录(`captcha_sent` → `login_cellphone`)—— **本项目当前用的**
- 游客 cookie(`register_anonimous`)绕过验证
- 二维码登录(`login_qr_key` / `login_qr_create` / `login_qr_check`)—— 包里**有**,项目**未接入**

### 9.3 VIP / 版权

- 灰色歌曲(无版权)`song_url_v1` 会返回 `url: null`
- 音质等级 `level`:`standard` / `higher` / `exhigh` / `lossless` / `hires`
  - 上游 `SoundQualityType` 枚举里没有 `higher`,但实际请求可用
  - 上游还支持 `jyeffect` / `jymaster` / `sky` / `vivid`,项目未在 UI 里暴露
- 播放地址是**临时直链**,过期约 20 分钟 —— 本项目用本机 302 定向 server
  (`lib/app/services/local_redirect_server.dart`)兜住

### 9.4 必选参数缺失

`method_spec.dart` 里没写 `defaultIfMissing` 的槽位,缺省时会传 `null`。
**调用前自己校验**,否则后端返 400 查不到原因。

### 9.5 已知问题

| 问题 | 说明 |
| --- | --- |
| 依赖解析到 hosted 版本 | `pubspec.yaml` 的注释指向本地 checkout(`/home/cmach_socket/projects/ncm_api_enhanced`,0.3.0),但**没有 `path:` 覆盖**,实际用的是 pub.dev 上的 **0.2.2**。两者公开 API 一致,但 0.3.0 修了 `noSuchMethod` 具名参数的 `Symbol("...")` 剥离 bug —— 0.2.2 下 `api.album(id: 1)` 会把 key 变成 `Symbol("id")`。项目统一走 `api.call(method, query)`,不受影响。 |
| 上游 d.ts 与 module 文件不同步 | `interface.d.ts` 里声明了 6 个没有对应 module 文件的函数(`comment_hotwall_list`、`listen_together_status`、`user_safe`、`yunbei_ad_task_*`);另有 7 个 module 文件没有 d.ts 签名(`like_v1`、`song_simi_get`、`song_wiki_info`、`yunbei_task_*_v1` 等)。调用会走到 node 侧的 unknown method。 |
| `lyric_new` 逐字歌词 | 返回 `yrc.lyric`,格式为 `[行起始ms,行时长ms,字起始ms,字时长(厘秒),?,文字]`,与上游 Python SDK 的字段顺序不同。解析见 `lib/app/data/repositories/lyrics_repository.dart`。 |

---

## 附录 A:上游完整接口目录(439)

上游 `@neteasecloudmusicapienhanced/api` 共 **439** 个 module 函数,`NcmApi` 的 `_methodNames` 白名单与之完全一致 —— `api.call(name, ...)` 传错名字会同步抛 `ArgumentError`。

调用方式统一是 `api.call(name, queryDict)`,query 字段名见下表。
所有接口都额外接受 `RequestBaseConfig`:`cookie` / `realIP` / `proxy` / `randomCNIP`。
带 `limit` / `offset` 的接口来自上游 `MultiPageConfig`。

> **本项目只登记了其中 28 个**(见 §6)。要用别的接口,先在 `method_spec.dart` 登记。

### 登录 / 注册

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `activate_init_profile` | 初始化名字 | `/api/activate/initProfile` | `nickname` | — |
| `captcha_safe_sent` | 发送安全验证码 | `/api/sms/captcha/safe/sent` | — | `ctcode` |
| `captcha_sent` | 发送验证码 | `/api/sms/captcha/sent` | `phone` | `ctcode` |
| `captcha_sent_v1` | 发送验证码 | `/api/middle/captcha/sent/v1` | `phone` | `ctcode` |
| `captcha_verify` | 校验验证码 | `/api/sms/captcha/verify` | `phone`, `captcha` | `ctcode` |
| `cellphone_existence_check` | 检测手机号码是否已注册 | `/api/cellphone/existence/check` | `phone`, `countrycode` | — |
| `login` | 邮箱登录 | `/api/w/login` | `email`, `md5_password` | — |
| `login_cellphone` | 手机登录 | `/api/w/login/cellphone` | `phone`, `captcha` | `countrycode` |
| `login_qr_check` | — | `/api/login/qrcode/client/login` | — | `key` |
| `login_qr_create` | — | `https://music.163.com/login?codekey={key}(本地生成二维码)` | — | `key`, `qrimg` |
| `login_qr_key` | — | `/api/login/qrcode/unikey` | — | — |
| `login_refresh` | 登录刷新 | `/api/login/token/refresh` | — | — |
| `login_status` | — | `/api/w/nuser/account/get` | — | — |
| `logout` | 退出登录 | `/api/logout` | — | — |
| `nickname_check` | — | `/api/nickname/duplicated` | `nickname` | — |
| `rebind` | 更换手机 | `/api/user/replaceCellphone` | `captcha`, `phone`, `oldcaptcha` | `ctcode` |
| `register_anonimous` | 获取游客cookie | `/api/register/anonimous` | — | — |
| `register_cellphone` | 注册账号 | `/api/w/register/cellphone` | `captcha`, `phone`, `password`, `nickname` | — |
| `register_checktoken_v2` | 易盾反作弊 Token 注册端点 | `易盾 Watchman SDK(本地)` | — | `refresh` |
| `register_checktoken_v3` | 易盾反作弊 Token 注册端点 | `易盾 Watchman SDK(本地)` | — | `refresh` |
| `register_xeapikey` | — | `/api/gorilla/anti/crawler/security/key/get` | — | `deviceId`, `currentKeyVersion` |

### 用户

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `avatar_upload` | — | `/api/user/avatar/upload/v1` | — | — |
| `countries_code_list` | 国家编码列表 | `/api/lbs/countries/v1` | — | — |
| `fanscenter_basicinfo_age_get` | 粉丝年龄比例 | `/api/fanscenter/basicinfo/age/get` | — | — |
| `fanscenter_basicinfo_gender_get` | 粉丝性别比例 | `/api/fanscenter/basicinfo/gender/get` | — | — |
| `fanscenter_basicinfo_province_get` | 粉丝省份比例 | `/api/fanscenter/basicinfo/province/get` | — | — |
| `fanscenter_overview_get` | 粉丝数量 | `/api/fanscenter/overview/get` | — | — |
| `fanscenter_trend_list` | 粉丝来源 | `/api/fanscenter/trend/list` | — | `startTime`, `endTime`, `type` |
| `pl_count` | 私信和通知接口 | `/api/pl/count` | — | — |
| `simi_user` | 相似用户 | `/api/discovery/simiUser` | `id` | `limit`, `offset` |
| `user_account` | — | `/api/nuser/account/get` | — | — |
| `user_audio` | 用户创建的电台 | `/api/djradio/get/byuser` | `uid` | — |
| `user_binding` | — | `/api/v1/user/bindings/{uid}` | — | `uid` |
| `user_bindingcellphone` | — | `/api/user/bindingCellphone` | `phone`, `captcha` | `countrycode`, `password` |
| `user_cloud` | 云盘数据 | `/api/v1/cloud/get` | — | `limit`, `offset` |
| `user_cloud_del` | 云盘歌曲删除 | `/api/cloud/del` | `id` | — |
| `user_cloud_detail` | 云盘数据详情 | `/api/v1/cloud/get/byids` | `id` | — |
| `user_comment_history` | — | `/api/comment/user/comment/history` | `uid` | `limit`, `time` |
| `user_detail` | 用户详情 | `/api/v1/user/detail/{uid}` | `uid` | — |
| `user_detail_new` | 用户详情 | `/api/w/v1/user/detail/{uid}` | `uid` | — |
| `user_dj` | 用户电台节目 | `/api/dj/program/{uid}` | `uid` | `limit`, `offset` |
| `user_event` | 用户动态 | `/api/event/get/{uid}` | `uid` | `lasttime`, `limit` |
| `user_event_all` | 获取当前登录用户可被上游枚举的全部动态 | `本地聚合(user_account + user_event)` | — | — |
| `user_follow_mixed` | 当前账号关注的用户/歌手 | `/api/user/follow/users/mixed/get/v2` | — | `size`, `cursor`, `scene` |
| `user_followeds` | 关注TA的人(粉丝) | `/api/user/getfolloweds/{uid}` | `uid` | `lasttime`, `limit` |
| `user_follows` | TA关注的人(关注) | `/api/user/getfollows/{uid}` | `uid` | `limit`, `offset` |
| `user_level` | 类别热门电台 | `/api/user/level` | — | — |
| `user_medal` | 用户徽章 | `/api/medal/user/page` | `uid` | — |
| `user_mutualfollow_get` | 用户是否互相关注 | `/api/user/mutualfollow/get` | `uid` | — |
| `user_playlist` | 用户歌单 | `/api/user/playlist` | `uid` | `limit`, `offset` |
| `user_playlist_collect` | 获取用户的收藏歌单列表 | `/api/user/playlist/collect` | `uid` | `limit`, `offset` |
| `user_playlist_create` | 获取用户的创建歌单列表 | `/api/user/playlist/create` | `uid` | `limit`, `offset` |
| `user_record` | 听歌排行 | `/api/v1/play/record` | `uid` | `type` |
| `user_replacephone` | — | `/api/user/replaceCellphone` | `phone`, `captcha`, `oldcaptcha` | `countrycode` |
| `user_social_status` | 用户状态 | `/api/social/user/status` | `uid` | — |
| `user_social_status_edit` | 用户状态 - 编辑 | `/api/social/user/status/edit` | `type` | `iconUrl`, `content`, `actionUrl` |
| `user_social_status_rcmd` | 用户状态 - 相同状态的用户 | `/api/social/user/status/rcmd` | — | — |
| `user_social_status_support` | 用户状态 - 支持设置的状态 | `/api/social/user/status/support` | — | — |
| `user_subcount` | 收藏计数 | `/api/subcount` | — | — |
| `user_update` | 编辑用户信息 | `/api/user/profile/update` | `birthday`, `city`, `gender`, `nickname`, `province`, `signature` | — |

### 歌单

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `comment_playlist` | 歌单评论 | `/api/v1/resource/comments/A_PL_0_{id}` | `id` | `before`, `limit`, `offset` |
| `listentogether_sync_playlist_get` | 一起听 当前列表获取 | `/api/listen/together/sync/playlist/get` | `roomId` | — |
| `playlist_category_list` | 歌单分类列表 | `/api/playlist/category/list` | — | `cat`, `limit` |
| `playlist_catlist` | 全部歌单分类 | `/api/playlist/catalogue` | — | — |
| `playlist_cover_update` | — | `/api/playlist/cover/update` | `id` | — |
| `playlist_create` | 创建歌单 | `/api/playlist/create` | `name`, `privacy` | `type` |
| `playlist_delete` | 删除歌单 | `/api/playlist/remove` | `id` | — |
| `playlist_desc_update` | 更新歌单描述 | `/api/playlist/desc/update` | `id`, `desc` | — |
| `playlist_detail` | 歌单详情 | `/api/v6/playlist/detail` | `id` | `s` |
| `playlist_detail_dynamic` | 歌单动态信息 | `/api/playlist/detail/dynamic` | `id` | — |
| `playlist_detail_rcmd_get` | 相关歌单推荐 | `/api/playlist/detail/rcmd/get` | `id` | — |
| `playlist_highquality_tags` | 精品歌单 tags | `/api/playlist/highquality/tags` | — | — |
| `playlist_hot` | 热门歌单分类 | `/api/playlist/hottags` | — | — |
| `playlist_import_name_task_create` | 歌单导入 - 元数据/文字/链接导入 | `/api/playlist/import/name/task/create` | — | `local`, `importStarPlaylist` |
| `playlist_import_task_status` | 歌单导入 - 任务状态 | `/api/playlist/import/task/status/v2` | `id` | — |
| `playlist_mylike` | — | `/api/mlog/playlist/mylike/bytime/get` | `limit` | `time` |
| `playlist_name_update` | 更新歌单名 | `/api/playlist/update/name` | `id`, `name` | — |
| `playlist_order_update` | 编辑歌单顺序 | `/api/playlist/order/update` | `ids` | — |
| `playlist_privacy` | 公开隐私歌单 | `/api/playlist/update/privacy` | `id` | — |
| `playlist_subscribe` | 收藏与取消收藏歌单 | `/api/playlist/${path}` | `t`, `id` | — |
| `playlist_subscribers` | 歌单收藏者 | `/api/playlist/subscribers` | — | `id`, `limit`, `offset` |
| `playlist_tags_update` | 更新歌单标签 | `/api/playlist/tags/update` | `id`, `tags` | — |
| `playlist_track_add` | — | `/api/playlist/track/add` | `ids` | `pid` |
| `playlist_track_all` | 通过传过来的歌单id拿到所有歌曲数据 | `/api/v6/playlist/detail` | `id` | `s`, `limit`, `offset` |
| `playlist_track_delete` | 收藏单曲到歌单 从歌单删除歌曲 | `/api/playlist/track/delete` | `ids` | `pid` |
| `playlist_tracks` | 收藏单曲到歌单 从歌单删除歌曲 | `/api/playlist/manipulate/tracks` | `op`, `pid`, `tracks` | — |
| `playlist_update` | 编辑歌单 | `/api/batch` | `id`, `name` | `desc`, `tags` |
| `playlist_update_playcount` | 歌单打卡 | `/api/playlist/update/playcount` | — | `id` |
| `playlist_video_recent` | — | `/api/playlist/video/recent` | — | — |
| `record_recent_playlist` | — | `/api/play-record/playlist/list` | — | `limit` |
| `related_playlist` | 相关歌单 | `https://music.163.com/playlist?id={id}(网页抓取)` | `id` | — |
| `send_playlist` | 私信歌单 | `/api/msg/private/send` | `playlist`, `msg`, `user_ids` | — |
| `simi_playlist` | 相似歌单 | `/api/discovery/simiPlaylist` | `id` | `limit`, `offset` |
| `style_playlist` | 曲风-歌单 | `/api/style-tag/home/playlist` | `tagId` | `size`, `cursor` |
| `top_playlist` | 分类歌单 | `/api/playlist/list` | — | `cat`, `order`, `limit`, `offset` |
| `top_playlist_highquality` | 精品歌单 | `/api/playlist/highquality/list` | — | `cat`, `before`, `limit` |

### 歌曲

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `check_music` | 歌曲可用性 | `/api/song/enhance/player/url` | `id`, `br` | — |
| `simi_song` | 相似歌曲 | `/api/v1/discovery/simiSong` | `id` | `limit`, `offset` |
| `song_chorus` | 副歌时间 | `/api/song/chorus` | `id` | — |
| `song_cloud_download` | 从云盘获取歌曲下载链接 | `/api/cloud/dowonload` | `id` | — |
| `song_copyright_rcmd` | 灰色歌曲的其他版本推荐 | `/api/song/copyright/rcmd` | — | `songid`, `id` |
| `song_creators` | 歌曲创作者信息 | `/api/song/creators` | `id` | — |
| `song_detail` | 歌曲详情 | `/api/v3/song/detail` | `ids` | — |
| `song_downlist` | 会员下载歌曲记录 | `/api/member/song/downlist` | — | `limit`, `offset` |
| `song_download_url` | 获取客户端歌曲下载链接 | `/api/song/enhance/download/url` | `id` | `br` |
| `song_download_url_v1` | 获取客户端歌曲下载链接 - v1 | `/api/song/enhance/download/url/v1` | `id`, `level` | — |
| `song_dynamic_cover` | 歌曲动态封面 | `/api/songplay/dynamic-cover` | `id` | — |
| `song_like` | 喜欢歌曲 | `/api/song/like` | `id` | `like`, `uid` |
| `song_like_check` | 歌曲是否喜爱 | `/api/song/like/check` | `ids` | — |
| `song_lyrics_mark` | 歌词摘录 - 歌词摘录信息 | `/api/song/play/lyrics/mark/song` | `id` | — |
| `song_lyrics_mark_add` | 歌词摘录 - 添加/修改摘录歌词 | `/api/song/play/lyrics/mark/add` | `id` | `markId`, `data` |
| `song_lyrics_mark_del` | 歌词摘录 - 删除摘录歌词 | `/api/song/play/lyrics/mark/del` | `id` | — |
| `song_lyrics_mark_user_page` | 歌词摘录 - 我的歌词本 | `/api/song/play/lyrics/mark/user/page` | — | `limit`, `offset` |
| `song_monthdownlist` | 会员本月下载歌曲记录 | `/api/member/song/monthdownlist` | — | `limit`, `offset` |
| `song_music_detail` | 歌曲音质详情 | `/api/song/music/detail/get` | `id` | — |
| `song_order_update` | 更新歌曲顺序 | `/api/playlist/manipulate/tracks` | `pid`, `ids` | — |
| `song_purchased` | 已购单曲 | `/api/single/mybought/song/list` | — | `limit`, `offset` |
| `song_red_count` | 歌曲红心数量 | `/api/song/red/count` | `id` | — |
| `song_simi_get` | 插播相似歌曲 | `/api/link/position/show/resource` | — | `id` |
| `song_singledownlist` | 已购买单曲 | `/api/member/song/singledownlist` | — | `limit`, `offset` |
| `song_url` | 歌曲链接 | `/api/song/enhance/player/url` | `id` | `br` |
| `song_url_match` | 网易云歌曲解灰(适配SPlayer的UNM-Server) | `第三方 UNM-Server(由 query 指定)` | `id` | `source` |
| `song_url_ncmget` | 夹带私货的东西就不要放在这里了 | `不提供(恒返回空数组)` | — | — |
| `song_url_v1` | 歌曲链接 - v1 | `/api/song/enhance/player/url/v1` | `id`, `level` | — |
| `song_url_v1_302` | 获取客户端歌曲下载链接 - v1 | `/api/song/enhance/download/url/v1` | `id`, `level` | — |
| `song_wiki_info` | 歌曲百科 | `/api/link/page/parent/relation/construct/info` | — | `id` |
| `song_wiki_summary` | 音乐百科基础信息 | `/api/song/play/about/block/page` | `id` | — |
| `top_song` | 新歌速递 | `/api/v1/discovery/new/songs` | `type` | — |

### 歌词

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `cloud_lyric_get` | 获取云盘歌词 | `/api/cloud/lyric/get` | `uid`, `sid` | — |
| `lyric` | 歌词 | `/api/song/lyric` | `id` | — |
| `lyric_new` | 新版歌词 - 包含逐字歌词 | `/api/song/lyric/v1` | `id` | — |
| `voice_lyric` | — | `/api/voice/lyric/get` | `id` | — |

### 专辑

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `album` | 专辑内容 | `/api/v1/album/{id}` | `id` | — |
| `album_detail` | 数字专辑详情 | `/api/vipmall/albumproduct/detail` | `id` | — |
| `album_detail_dynamic` | 专辑动态信息 | `/api/album/detail/dynamic` | `id` | — |
| `album_list` | 数字专辑-新碟上架 | `/api/vipmall/albumproduct/list` | `type` | `area`, `limit`, `offset` |
| `album_list_style` | 数字专辑-语种风格馆 | `/api/vipmall/appalbum/album/style` | — | `area`, `limit`, `offset` |
| `album_new` | 全部新碟 | `/api/album/new` | — | `area`, `limit`, `offset` |
| `album_newest` | 最新专辑 | `/api/discovery/newAlbum` | — | — |
| `album_privilege` | 获取专辑歌曲的音质 | `/api/album/privilege` | `id` | — |
| `album_songsaleboard` | 数字专辑&数字单曲-榜单 | `/api/feealbum/songsaleboard/${type}/type` | — | `albumType`, `type`, `year` |
| `album_sub` | 收藏/取消收藏专辑 | `/api/album/{t}` | `id`, `t` | — |
| `album_sublist` | 已收藏专辑列表 | `/api/album/sublist` | — | `limit`, `offset` |
| `digitalAlbum_detail` | 数字专辑详情 | `/api/vipmall/albumproduct/detail` | `id` | — |
| `digitalAlbum_ordering` | 购买数字专辑 | `/api/ordering/web/digital` | `payment`, `id`, `quantity` | — |
| `digitalAlbum_purchased` | 我的数字专辑 | `/api/digitalAlbum/purchased` | — | `limit`, `offset` |
| `digitalAlbum_sales` | 数字专辑销量 | `/api/vipmall/albumproduct/album/query/sales` | `ids` | — |
| `top_album` | 新碟上架 | `/api/discovery/new/albums/area` | — | `area`, `type`, `year`, `mouth`, `limit`, `offset` |

### 艺人

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `artist_album` | 歌手专辑列表 | `/api/artist/albums/{id}` | `id` | `limit`, `offset` |
| `artist_desc` | 歌手介绍 | `/api/artist/introduction` | `id` | — |
| `artist_detail` | — | `/api/artist/head/info/get` | `id` | — |
| `artist_detail_dynamic` | 歌手动态信息 | `/api/artist/detail/dynamic` | `id` | — |
| `artist_fans` | 歌手粉丝 | `/api/artist/fans/get` | `id` | `limit`, `offset` |
| `artist_follow_count` | 歌手粉丝数量 | `/api/artist/follow/count/get` | `id` | — |
| `artist_list` | 歌手分类 | `/api/v1/artist/list` | `area` | `initial`, `type`, `limit`, `offset` |
| `artist_mv` | 歌手相关MV | `/api/artist/mvs` | `id` | `limit`, `offset` |
| `artist_new_mv` | — | `/api/sub/artist/new/works/mv/list` | — | `limit`, `startTimestamp` |
| `artist_new_song` | — | `/api/sub/artist/new/works/song/list` | — | `limit`, `startTimestamp` |
| `artist_new_song_mv_list_v2` | 获取关注歌手的新歌曲和 MV | `/api/sub/artist/new/works/song-mv/list/v2` | — | `startTimestamp`, `before`, `sourceType`, `limit`, `firstRequest` |
| `artist_new_song_playall` | 获取所有关注歌手最近的 50 首新歌 | `/api/sub/artist/new/works/song/playall` | — | — |
| `artist_songs` | — | `/api/v1/artist/songs` | `id` | `order`, `limit`, `offset` |
| `artist_sub` | 收藏与取消收藏歌手 | `/api/artist/{t}` | `id`, `t` | — |
| `artist_sublist` | 关注歌手列表 | `/api/artist/sublist` | — | `limit`, `offset` |
| `artist_top_song` | 歌手热门 50 首歌曲 | `/api/artist/top/song` | `id` | — |
| `artist_video` | 歌手相关视频 | `/api/mlog/artist/video` | `id` | `size`, `cursor`, `order` |
| `artists` | 歌手单曲 | `/api/v1/artist/{id}` | `id` | — |
| `simi_artist` | 相似歌手 | `/api/discovery/simiArtist` | `id` | — |
| `style_artist` | 曲风-歌手 | `/api/style-tag/home/artist` | `tagId` | `size`, `cursor` |
| `toplist_artist` | 歌手榜 | `/api/toplist/artist` | — | `type` |
| `ugc_artist_get` | 歌手简要百科信息 | `/api/rep/ugc/artist/get` | `id` | — |
| `ugc_artist_search` | 搜索歌手 | `/api/rep/ugc/artist/search` | `keyword` | `limit` |

### 视频 / MV

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `broadcast_category_region_get` | 广播电台 - 分类/地区信息 | `/api/voice/broadcast/category/region/get` | — | — |
| `broadcast_channel_collect_list` | 广播电台 - 我的收藏 | `/api/content/channel/collect/list` | — | `limit`, `offset` |
| `broadcast_channel_currentinfo` | 广播电台 - 电台信息 | `/api/voice/broadcast/channel/currentinfo` | `id` | — |
| `broadcast_channel_list` | 广播电台 - 全部电台 | `/api/voice/broadcast/channel/list` | — | `categoryId`, `regionId`, `lastId`, `score`, `limit`, `offset` |
| `broadcast_sub` | 广播电台 - 收藏/取消收藏电台 | `/api/content/interact/collect` | `t`, `id` | — |
| `mlog_music_rcmd` | 歌曲相关视频 | `/api/mlog/rcmd/feed/list` | — | `mvid`, `songid`, `limit` |
| `mlog_to_video` | 将mlog id转为video id | `/api/mlog/video/convert/id` | — | `id` |
| `mlog_url` | mlog链接 | `/api/mlog/detail/v1` | — | `id`, `res` |
| `mv_all` | 全部MV | `/api/mv/all` | — | `area`, `type`, `order`, `limit`, `offset` |
| `mv_detail` | MV详情 | `/api/v1/mv/detail` | — | `mvid` |
| `mv_detail_info` | MV 点赞转发评论数数据 | `/api/comment/commentthread/info` | `mvid` | — |
| `mv_exclusive_rcmd` | 网易出品 | `/api/mv/exclusive/rcmd` | — | `limit`, `offset` |
| `mv_first` | 最新MV | `/api/mv/first` | — | `area`, `limit` |
| `mv_sub` | 收藏与取消收藏MV | `/api/mv/{t}` | `t`, `mvid` | — |
| `mv_sublist` | 已收藏MV列表 | `/api/cloudvideo/allvideo/sublist` | — | `limit`, `offset` |
| `mv_url` | MV链接 | `/api/song/enhance/play/mv/url` | — | `id`, `r` |
| `related_allvideo` | 相关视频 | `/api/cloudvideo/v1/allvideo/rcmd` | `id` | — |
| `simi_mv` | 相似MV | `/api/discovery/simiMV` | `mvid` | — |
| `video_category_list` | 视频分类列表 | `/api/cloudvideo/category/list` | — | `limit`, `offset` |
| `video_detail` | 视频详情 | `/api/cloudvideo/v1/video/detail` | `id` | — |
| `video_detail_info` | 视频点赞转发评论数数据 | `/api/comment/commentthread/info` | `vid` | — |
| `video_group` | 视频标签/分类下的视频 | `/api/videotimeline/videogroup/otherclient/get` | `id` | `offset` |
| `video_group_list` | 视频标签列表 | `/api/cloudvideo/group/list` | — | — |
| `video_sub` | 收藏与取消收藏视频 | `/api/cloudvideo/video/{t}` | `id` | `t` |
| `video_timeline_all` | 全部视频列表 | `/api/videotimeline/otherclient/get` | — | `offset` |
| `video_timeline_recommend` | 推荐视频 | `/api/videotimeline/get` | — | `offset` |
| `video_url` | 视频链接 | `/api/cloudvideo/playurl` | `id` | `res` |

### 电台 / 声音

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `djRadio_top` | 电台排行榜获取 | `/api/expert/worksdata/works/top/get` | — | `djRadioId`, `sortIndex`, `dataGapDays`, `dataType` |
| `dj_banner` | 电台banner | `/api/djradio/banner/get` | — | — |
| `dj_category_excludehot` | 电台非热门类型 | `/api/djradio/category/excludehot` | — | — |
| `dj_category_recommend` | 电台推荐类型 | `/api/djradio/home/category/recommend` | — | — |
| `dj_catelist` | 电台分类列表 | `/api/djradio/category/get` | — | — |
| `dj_detail` | 电台详情 | `/api/djradio/v2/get` | `rid` | — |
| `dj_difm_all_style_channel` | DIFM电台 - 分类 | `/api/dj/difm/all/style/channel/v2` | — | `sources` |
| `dj_difm_channel_subscribe` | DIFM电台 - 收藏频道 | `/api/dj/difm/channel/subscribe` | `id` | — |
| `dj_difm_channel_unsubscribe` | DIFM电台 - 取消收藏频道 | `/api/dj/difm/channel/unsubscribe` | `id` | — |
| `dj_difm_playing_tracks_list` | DIFM电台 - 播放列表 | `/api/dj/difm/playing/tracks/list` | `channelId` | `limit`, `source` |
| `dj_difm_subscribe_channels_get` | DIFM电台 - 收藏列表 | `/api/dj/difm/subscribe/channels/get/v2` | — | `sources` |
| `dj_hot` | 热门电台 | `/api/djradio/hot/v1` | — | `limit`, `offset` |
| `dj_paygift` | 付费电台 | `/api/djradio/home/paygift/list` | — | `limit`, `offset` |
| `dj_personalize_recommend` | 电台个性推荐 | `/api/djradio/personalize/rcmd` | — | `limit` |
| `dj_program` | 电台节目列表 | `/api/dj/program/byradio` | `rid`, `asc` | `limit`, `offset` |
| `dj_program_detail` | 电台节目详情 | `/api/dj/program/detail` | `id` | — |
| `dj_program_toplist` | 电台节目榜 | `/api/program/toplist/v1` | — | `limit`, `offset` |
| `dj_program_toplist_hours` | 电台24小时节目榜 | `/api/djprogram/toplist/hours` | — | `limit` |
| `dj_radio_hot` | 类别热门电台 | `/api/djradio/hot` | `cateId` | `limit`, `offset` |
| `dj_recommend` | 精选电台 | `/api/djradio/recommend/v1` | — | — |
| `dj_recommend_type` | 精选电台分类 | `/api/djradio/recommend` | `type` | — |
| `dj_sub` | 订阅与取消电台 | `/api/djradio/{t}` | `t`, `rid` | — |
| `dj_sublist` | 订阅电台列表 | `/api/djradio/get/subed` | — | `limit`, `offset` |
| `dj_subscriber` | 电台详情 | `/api/djradio/subscriber` | `id` | `limit`, `time` |
| `dj_today_perfered` | 电台今日优选 | `/api/djradio/home/today/perfered` | — | `page` |
| `dj_toplist` | 新晋电台榜/热门电台榜 | `/api/djradio/toplist` | — | `type`, `limit`, `offset` |
| `dj_toplist_hours` | 电台24小时主播榜 | `/api/dj/toplist/hours` | — | `limit` |
| `dj_toplist_newcomer` | 电台新人榜 | `/api/dj/toplist/newcomer` | — | `limit`, `offset` |
| `dj_toplist_pay` | 付费精品 | `/api/djradio/toplist/pay` | — | `limit` |
| `dj_toplist_popular` | 电台最热主播榜 | `/api/dj/toplist/popular` | — | `limit` |
| `voice_delete` | — | `/api/content/voice/delete` | `ids` | — |
| `voice_detail` | — | `/api/voice/workbench/voice/detail` | `id` | — |
| `voice_upload` | — | `/api/nos/token/alloc` | `songFile`, `name`, `data`, `name`, `data`, `voiceListId`, `categoryId`, `secondCategoryId`, `description` | `imgFile`, `coverImgId`, `songName`, `privacy`, `publishTime`, `autoPublish`, `autoPublishText`, `orderNo`, `composedSongs` |
| `voicelist_detail` | — | `/api/voice/workbench/voicelist/detail` | `id` | — |
| `voicelist_list` | — | `/api/voice/workbench/voices/by/voicelist` | `voiceListId` | `limit`, `offset` |
| `voicelist_list_search` | 声音搜索 | `/api/voice/workbench/voice/list` | — | `limit`, `offset`, `name`, `displayStatus`, `type`, `voiceFeeType`, `radioId` |
| `voicelist_my_created` | 我创建的播客声音 | `/api/social/my/created/voicelist/v1` | — | `limit` |
| `voicelist_search` | — | `/api/search/voicelist/get` | — | `keyword`, `limit`, `offset` |
| `voicelist_trans` | — | `/api/voice/workbench/radio/program/trans` | — | `radioId`, `programId`, `position`, `limit`, `offset` |

### 排行榜

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `chart_detail` | 获取指定维度音乐排行榜详情 | `/api/chart/detail` | `chartCode`, `targetId`, `targetType` | — |
| `chart_song_detail` | 获取指定维度音乐排行榜列表 | `/api/chart/song/detail` | `chartCode`, `targetId`, `targetType` | — |
| `top_artists` | 热门歌手 | `/api/artist/top` | — | `limit`, `offset` |
| `top_list` | 排行榜 | `/api/playlist/v4/detail` | `id` | — |
| `top_mv` | MV排行榜 | `/api/mv/toplist` | — | `area`, `limit`, `offset` |
| `toplist` | 所有榜单介绍 | `/api/toplist` | — | — |
| `toplist_detail` | 所有榜单内容摘要 | `/api/toplist/detail` | — | — |
| `toplist_detail_v2` | 所有榜单内容摘要v2 | `/api/toplist/detail/v2` | — | — |

### 搜索

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `cloudsearch` | 搜索 | `/api/cloudsearch/pc` | `keywords` | `type`, `limit`, `offset` |
| `search` | 搜索 | `/api/search/voice/get` | `keywords` | `type`, `limit`, `offset` |
| `search_default` | 默认搜索关键词 | `/api/search/defaultkeyword/get` | — | — |
| `search_hot` | 热门搜索 | `/api/search/hot` | — | — |
| `search_hot_detail` | 热搜列表 | `/api/hotsearchlist/get` | — | — |
| `search_match` | 本地歌曲匹配音乐信息 | `/api/search/match/new` | — | `title`, `album`, `artist`, `duration`, `md5` |
| `search_multimatch` | 多类型搜索 | `/api/search/suggest/multimatch` | `keywords` | `type` |
| `search_suggest` | 搜索建议 | `/api/search/suggest/` | `keywords` | `type` |
| `search_suggest_pc` | 搜索建议pc端 | `/api/search/pc/suggest/keyword/get` | `keyword` | — |

### 评论

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `comment` | — | `/api/resource/comments/{t}` | `type`, `t`, `threadId`, `content`, `commentId` | — |
| `comment_add` | — | `/api/resource/comments/add` | `id`, `type`, `content` | — |
| `comment_album` | 专辑评论 | `/api/v1/resource/comments/R_AL_3_{id}` | `id` | `before`, `limit`, `offset` |
| `comment_delete` | — | `/api/resource/comments/delete` | `id`, `type`, `cid` | — |
| `comment_dj` | 电台评论 | `/api/v1/resource/comments/A_DJ_1_{id}` | `id` | `before`, `limit`, `offset` |
| `comment_event` | 获取动态评论 | `/api/v1/resource/comments/{threadId}` | `threadId` | `before`, `limit`, `offset` |
| `comment_floor` | — | `/api/resource/comment/floor/get` | `id`, `parentCommentId`, `type` | `limit`, `time` |
| `comment_hot` | — | `/api/v1/resource/hotcomments/{type}{id}` | `id`, `type` | `before`, `limit`, `offset` |
| `comment_hug_list` | — | `/api/v2/resource/comments/hug/list` | `page`, `cursor`, `idCursor` | `pageSize` |
| `comment_info_list` | 评论统计数据 | `/api/resource/commentInfo/list` | — | `ids`, `type` |
| `comment_like` | — | `/api/v1/comment/{t}` | `id`, `type`, `t`, `cid` | `threadId` |
| `comment_music` | 歌曲评论 | `/api/v1/resource/comments/R_SO_4_{id}` | `id` | `before`, `limit`, `offset` |
| `comment_mv` | MV评论 | `/api/v1/resource/comments/R_MV_5_{id}` | `id` | `before`, `limit`, `offset` |
| `comment_new` | — | `/api/v2/resource/comments` | `id` | `type`, `pageNo`, `pageSize`, `sortType` |
| `comment_reply` | — | `/api/v1/resource/comments/reply` | `id`, `type`, `cid`, `content` | — |
| `comment_report` | 举报评论 | `/api/report/reportcomment` | `id`, `cid`, `reason` | — |
| `comment_video` | 视频评论 | `/api/v1/resource/comments/R_VI_62_{id}` | `id` | `before`, `limit`, `offset` |
| `hug_comment` | — | `/api/v2/resource/comments/hug/listener` | `uid`, `cid`, `sid` | — |

### 动态 / 话题

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `event` | 获取动态列表 | `/api/v1/event/get` | — | `pagesize`, `lasttime` |
| `event_del` | 删除动态 | `/api/event/delete` | `evId` | — |
| `event_forward` | — | `/api/event/forward` | `forwords`, `evId`, `uid` | — |
| `event_privacy` | 修改本人动态的可见权限 | `/api/event/privacy/op` | `evId`, `privacy` | — |
| `hot_topic` | 热门话题 | `/api/act/hot` | — | `limit`, `offset` |
| `share_resource` | 分享歌曲到动态 | `/api/share/friends/resource` | — | `type`, `msg`, `id` |
| `topic_detail` | — | `/api/act/detail` | — | `actid` |
| `topic_detail_event_hot` | — | `/api/act/event/hot` | — | `actid` |
| `topic_sublist` | 收藏的专栏 | `/api/topic/sublist` | — | `limit`, `offset` |

### 关注

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `follow` | 关注与取消关注用户 | `/api/user/{t}/{id}` | `t`, `id` | — |
| `resource_like` | 点赞与取消点赞资源 | `/api/resource/{t}` | `t`, `type` | `id`, `threadId` |

### 播放模式

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `playmode_intelligence_list` | 智能播放 | `/api/playmode/intelligence/list` | `id`, `pid` | `sid`, `count` |
| `playmode_song_vector` | 云随机播放 | `/api/playmode/song/vector/get` | `ids` | — |

### 私信 / 通知

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `msg_comments` | 评论 | `/api/v1/user/comments/{uid}` | `uid` | `before`, `limit` |
| `msg_forwards` | @我 | `/api/forwards/get` | — | `limit`, `offset` |
| `msg_notices` | 通知 | `/api/msg/notices` | — | `limit`, `lasttime` |
| `msg_private` | 私信 | `/api/msg/private/users` | — | `limit`, `offset` |
| `msg_private_history` | 私信内容 | `/api/msg/private/history` | `uid` | `before`, `limit` |
| `msg_recentcontact` | 最近联系 | `/api/msg/recentcontact/get` | — | — |
| `send_album` | 私信专辑 | `/api/msg/private/send` | `id`, `user_ids` | `msg` |
| `send_song` | 私信歌曲 | `/api/msg/private/send` | `id`, `user_ids` | `msg` |
| `send_text` | 私信 | `/api/msg/private/send` | `msg`, `user_ids` | — |

### 云盘

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `cloud` | — | `/api/cloud/upload/check` | `songFile`, `name`, `data` | — |
| `cloud_import` | 云盘导入歌曲 | `/api/cloud/upload/check/v2` | `md5` | `id`, `bitrate`, `fileSize`, `artist`, `album`, `song` |
| `cloud_match` | — | `/api/cloud/user/song/match` | `uid`, `sid`, `asid` | — |
| `cloud_upload_complete` | — | `/api/upload/cloud/info/v2` | `songId`, `resourceId`, `md5`, `filename` | `song`, `artist`, `album`, `bitrate` |
| `cloud_upload_token` | — | `/api/cloud/upload/check` | `md5`, `fileSize`, `filename` | `bitrate` |

### 云贝

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `yunbei` | — | `/api/point/signed/get` | — | — |
| `yunbei_expense` | — | `/api/point/expense` | — | `limit`, `offset` |
| `yunbei_info` | — | `/api/v1/user/info` | — | — |
| `yunbei_rcmd_song` | 云贝推歌 | `/api/yunbei/rcmd/song/submit` | `id` | `reason` |
| `yunbei_rcmd_song_history` | 云贝推歌历史记录 | `/api/yunbei/rcmd/song/history/list` | — | `size`, `cursor` |
| `yunbei_receipt` | — | `/api/point/receipt` | — | `limit`, `offset` |
| `yunbei_sign` | — | `/api/pointmall/user/sign` | — | — |
| `yunbei_task_finish` | — | `/api/usertool/task/point/receive` | `userTaskId` | `depositCode` |
| `yunbei_task_finish_v1` | 云贝广告任务 - 完成任务领取云贝 | `/api/ad/power/yunbei/distribution/create` | — | `yunbeiAmount` |
| `yunbei_task_list_v1` | 云贝广告任务 - 查询今日任务状态 | `/api/ad/power/yunbei/distribution/list` | — | — |
| `yunbei_task_recommend_song` | 云贝广告任务 - 获取推荐歌曲 | `/api/ad/power/yunbei/distribution/recommend/song` | — | `offset`, `limit` |
| `yunbei_tasks` | — | `/api/usertool/task/list/all` | — | — |
| `yunbei_tasks_todo` | — | `/api/usertool/task/todo/query` | — | — |
| `yunbei_today` | — | `/api/point/today/get` | — | — |

### VIP

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `vip_growthpoint` | 会员成长值 | `/api/vipnewcenter/app/level/growhpoint/basic` | — | — |
| `vip_growthpoint_details` | 会员成长值领取记录 | `/api/vipnewcenter/app/level/growth/details` | — | `limit`, `offset` |
| `vip_growthpoint_get` | 领取会员成长值 | `/api/vipnewcenter/app/level/task/reward/get` | — | `ids` |
| `vip_growthpoint_getall` | 一键领取所有会员成长值 | `/api/vipnewcenter/app/level/task/reward/getall` | — | — |
| `vip_info` | 获取 VIP 信息 | `/api/music-vip-membership/front/vip/info` | — | `uid` |
| `vip_info_v2` | 获取 VIP 信息 | `/api/music-vip-membership/client/vip/info` | — | `uid` |
| `vip_sign` | 黑胶乐签打卡 | `/api/vip-center-bff/task/sign` | — | — |
| `vip_sign_detail` | 黑胶乐签打卡详情 | `/api/vipnewcenter/app/level/user/checkin/history/detail` | `timestamp` | — |
| `vip_sign_history` | 黑胶乐签打卡历史 / 状态查询 | `/api/vipnewcenter/app/minidesk/music/sign/pc` | — | `type` |
| `vip_sign_info` | 黑胶乐签未来签到信息 | `/api/vipnewcenter/app/user/sign/info` | — | — |
| `vip_tasks` | 会员任务 | `/api/vipnewcenter/app/level/task/list` | — | — |
| `vip_tasks_v1` | 会员任务 - 新版 | `/api/middle/vip/mission/user/progress/list` | — | `id` |
| `vip_timemachine` | 黑胶时光机 | `/api/vipmusic/newrecord/weekflow` | — | `startTime`, `endTime`, `limit` |

### 音乐人

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `musician_cloudbean` | 账号云豆数 | `/api/cloudbean/get` | — | — |
| `musician_cloudbean_obtain` | 领取云豆 | `/api/nmusician/workbench/mission/reward/obtain/new` | `id`, `period` | — |
| `musician_data_overview` | 音乐人数据概况 | `/api/creator/musician/statistic/data/overview/get` | — | — |
| `musician_play_trend` | 音乐人歌曲播放趋势 | `/api/creator/musician/play/count/statistic/data/trend/get` | `startTime`, `endTime` | — |
| `musician_sign` | 音乐人签到 | `/api/creator/user/access` | — | — |
| `musician_tasks` | 获取音乐人任务 | `/api/nmusician/workbench/mission/cycle/list` | — | — |
| `musician_tasks_new` | 获取音乐人任务 | `/api/nmusician/workbench/mission/stage/list ` | — | — |
| `musician_vip_tasks` | 获取音乐人任务 | `/api/nmusician/workbench/special/right/vip/info` | — | — |

### UGC / 活动

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `creator_authinfo_get` | 获取达人用户信息 | `/api/user/creator/authinfo/get` | — | — |
| `rep_ugc_activity_collect` | 云小编领取任务积分 | `/api/rep/ugc/activity/collect` | — | `activityId` |
| `rep_ugc_activity_get` | 云小编活动信息 | `/api/rep/ugc/activity/get` | — | — |
| `rep_ugc_exam_info_get` | 云小编考试状态 | `/api/rep/ugc/exam/info/get` | `examType` | — |
| `rep_ugc_exam_question_single_get` | 云小编考试取题 | `/api/rep/ugc/exam/question/single/get` | `examType`, `taskId` | — |
| `rep_ugc_exam_result_get` | 云小编考试结果 | `/api/rep/ugc/exam/result/get` | `examType`, `taskId` | — |
| `rep_ugc_exam_start` | 云小编考试开始 | `/api/rep/ugc/exam/start` | `examType` | — |
| `rep_ugc_exam_submit` | 云小编考试提交 | `/api/rep/ugc/exam/submit` | `examType`, `taskId`, `questionId`, `answer` | — |
| `rep_ugc_user_collect-vip` | 云小编领取一日会员 | `/api/rep/ugc/user/collect-vip` | — | `activityId` |
| `rep_ugc_user_get` | 云小编获取用户详情 | `/api/rep/ugc/user/get` | — | — |
| `rep_ugc_user_sign` | 云小编每日签到 | `/api/rep/ugc/user/sign` | — | — |
| `rep_ugc_user_vip` | 云小编查询会员任务状态 | `/api/rep/ugc/user/vip` | — | — |
| `sati_resource_list` | 助眠解压 - 获取标签下资源列表 | `/api/voice/sati/resource/list` | `tag` | — |
| `sati_resource_list_more` | 助眠解压 - 查看同类推荐 | `/api/voice/sati/resource/list/more/v1` | `id` | — |
| `sati_resource_sub` | 助眠解压 - 收藏 | `/api/voice/sati/resource/sub` | `id` | `cancel` |
| `sati_resource_sub_list` | 助眠解压 - 收藏列表 | `/api/voice/sati/resource/sub/list` | — | — |
| `sati_tag_list` | 助眠解压 - 标签列表 | `/api/voice/sati/tag/list` | — | — |
| `sati_timescene_resources_get` | 助眠解压 - 特定时间场景下的推荐资源 | `/api/voice/sati/timescene/resources/get` | — | — |
| `thinktank_audit_resource_detail` | 云小编获取任务 | `/api/thinktank/audit/resource/detail` | — | `type` |
| `thinktank_audit_resource_update` | 云小编提交任务 | `/api/thinktank/audit/resource/update` | `taskId`, `judgement` | `type` |
| `threshold_detail_get` | 获取达人达标信息 | `/api/influencer/web/apply/threshold/detail/get` | — | — |
| `ugc_album_get` | 专辑简要百科信息 | `/api/rep/ugc/album/get` | `id` | — |
| `ugc_detail` | 用户贡献内容 | `/api/rep/ugc/detail` | — | `auditStatus`, `type`, `sortBy`, `order`, `limit`, `offset` |
| `ugc_mv_get` | mv简要百科信息 | `/api/rep/ugc/mv/get` | `id` | — |
| `ugc_song_get` | 歌曲简要百科信息 | `/api/rep/ugc/song/get` | `id` | — |
| `ugc_user_devote` | 用户贡献条目、积分、云贝数量 | `/api/rep/ugc/user/devote` | — | — |

### 曲风

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `style_album` | 曲风-专辑 | `/api/style-tag/home/album` | `tagId` | `size`, `cursor`, `sort` |
| `style_detail` | 曲风详情 | `/api/style-tag/home/head` | `tagId` | — |
| `style_list` | 曲风列表 | `/api/tag/list/get` | — | — |
| `style_preference` | 曲风偏好 | `/api/tag/my/preference/get` | — | — |
| `style_song` | 曲风-歌曲 | `/api/style-tag/home/song` | `tagId` | `size`, `cursor`, `sort` |

### 乐谱

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `sheet_list` | 乐谱列表 | `/api/music/sheet/list/v1` | `id` | `abTest` |
| `sheet_preview` | 乐谱预览 | `/api/music/sheet/preview/info` | `id` | — |

### 设置 / Banner

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `banner` | 首页轮播图 | `/api/v2/banner/get` | — | `type` |
| `daily_signin` | 签到 | `/api/point/dailyTask` | — | `type` |
| `setting` | 设置 | `/api/user/setting` | — | — |
| `sign_happy_info` | — | `/api/sign/happy/info` | — | — |
| `signin_progress` | 签到进度 | `/api/act/modules/signin/v2/progress` | — | `moduleId` |

### 个性化推荐

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `fm_trash` | 垃圾桶 | `/api/radio/trash/add` | `id` | `time` |
| `history_recommend_songs` | 历史每日推荐歌曲 | `/api/discovery/recommend/songs/history/recent` | — | — |
| `history_recommend_songs_detail` | 历史每日推荐歌曲详情 | `/api/discovery/recommend/songs/history/detail` | — | `date` |
| `like` | 红心与取消红心歌曲 | `/api/radio/like` | `id` | `like`, `alg`, `time` |
| `like_v1` | 红心与取消红心歌曲- v1 | `/api/v1/radio/like` | — | `like`, `id` |
| `likelist` | 喜欢的歌曲(无序) | `/api/song/like/get` | `uid` | — |
| `personal_fm` | 私人FM | `/api/v1/radio/get` | — | — |
| `personal_fm_mode` | 私人FM - 模式选择 | `/api/v1/radio/get` | `mode` | `submode`, `limit` |
| `personalized` | 推荐歌单 | `/api/personalized/playlist` | — | `limit` |
| `personalized_djprogram` | 推荐电台 | `/api/personalized/djprogram` | — | — |
| `personalized_mv` | 推荐MV | `/api/personalized/mv` | — | — |
| `personalized_newsong` | 推荐新歌 | `/api/personalized/newsong` | — | `area`, `limit` |
| `personalized_privatecontent` | 独家放送 | `/api/personalized/privatecontent` | — | — |
| `personalized_privatecontent_list` | 独家放送列表 | `/api/v2/privatecontent/list` | — | `limit`, `offset` |
| `program_recommend` | 推荐节目 | `/api/program/recommend/v1` | `type` | `limit`, `offset` |
| `recommend_resource` | 每日推荐歌单 | `/api/v1/discovery/recommend/resource` | — | — |
| `recommend_songs` | 每日推荐歌曲 | `/api/v3/discovery/recommend/songs` | — | `afresh` |
| `recommend_songs_dislike` | 每日推荐歌曲-不感兴趣 | `/api/v2/discovery/recommend/dislike` | `id` | — |

### 一起听

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `listentogether_accept` | — | `/api/listen/together/play/invitation/accept` | `roomId`, `inviterId` | — |
| `listentogether_end` | 一起听 结束房间 | `/api/listen/together/end/v2` | `roomId` | — |
| `listentogether_heatbeat` | 一起听 发送心跳 | `/api/listen/together/heartbeat` | `roomId`, `songId`, `playStatus`, `progress` | — |
| `listentogether_play_command` | 一起听 发送播放状态 | `/api/listen/together/play/command/report` | `roomId`, `commandType`, `playStatus`, `formerSongId`, `targetSongId`, `clientSeq` | `progress` |
| `listentogether_room_check` | 一起听 房间情况 | `/api/listen/together/room/check` | `roomId` | — |
| `listentogether_room_create` | 一起听创建房间 | `/api/listen/together/room/create` | — | — |
| `listentogether_status` | 一起听状态 | `/api/listen/together/status/get` | — | — |
| `listentogether_sync_list_command` | 一起听 更新播放列表 | `/api/listen/together/sync/list/command/report` | `roomId`, `commandType`, `userId`, `version`, `randomList`, `displayList` | — |

### 验证 / 匹配

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `audio_match` | — | `https://interface.music.163.com/api/music/audio/match` | `duration`, `audioFP` | — |
| `get_userids` | — | `/api/user/getUserIds` | `nicknames` | — |
| `verify_getQr` | — | `/api/frontrisk/verify/getqrcode` | `vid`, `type`, `token`, `evid`, `sign` | — |
| `verify_qrcodestatus` | — | `/api/frontrisk/verify/qrcodestatus` | `qr` | — |

### 其他 / 统计

| 方法 | 说明 | 路径 | 必选参数 | 可选参数 |
| --- | --- | --- | --- | --- |
| `ad_get` | 获取广告 | `/api/ad/get` | — | `type_ids` |
| `ad_listening_rights` | 获取免费听时长状态 | `/api/ad/homepage/free/tab/extend/v2` | — | — |
| `ad_listening_rights_gain` | 看广告免费听歌 - 领取免费听权益 | `/api/ad/listening/rights/gain` | — | `reqUid`, `uid`, `exposureTime`, `clickTime`, `extraRightsType`, `playContinuously`, `source`, `creativeType`, `rightsGainMethod`, `extraRightsGainMethod`, `extraRightsGainDuration`, `nextRightsGainDuration`, `rightsGainType`, `rightsGainDuration`, `gainMethodStep`, `generalRightsInfo`, `rightsExtJson`, `appInfo`, `contextInfo`, `installed`, `sniffTime`, `type_ids` |
| `aidj_content_rcmd` | 私人 DJ | `/api/aidj/content/rcmd/info` | — | `latitude`, `longitude` |
| `api` | — | `任意 URI(由 query.uri 传入)` | `uri` | `data`, `crypto` |
| `batch` | 批量请求接口 | `/api/batch` | `index` | — |
| `calendar` | — | `/api/mcalendar/detail` | `endTime` | `startTime` |
| `decrypt` | — | `本地解密(不发请求)` | — | `crypto`, `data`, `hexString`, `isReq` |
| `device_kickoff` | 强制下线设备 | `/api/middle/user/security/device/kickoff` | `deviceKey` | `captcha` |
| `device_list` | 登录设备列表 | `/api/middle/user/device/list` | — | — |
| `eapi_decrypt` | — | `本地解密(不发请求)` | `hexString` | `isReq` |
| `homepage_block_page` | 首页-发现 block page | `/api/homepage/block/page` | — | `refresh`, `cursor` |
| `homepage_dragon_ball` | 首页-发现 dragon ball | `/api/homepage/dragon/ball/static` | — | — |
| `inner_version` | — | `本地读取 package.json` | — | — |
| `lbs_city_code` | 多级行政区划数据获取接口 | `/api/lbs/city/code` | — | `bizCode` |
| `listen_data_realtime_report` | 听歌足迹 - 本周/本月收听时长 | `/api/content/activity/listen/data/realtime/report` | — | `type` |
| `listen_data_report` | 听歌足迹 - 周/月/年收听报告 | `/api/content/activity/listen/data/report` | — | `type`, `endTime` |
| `listen_data_song_play_rank` | 听歌足迹 - 歌曲播放排行 (Top20) | `/api/content/activity/listen/data/song/play/rank` | — | `type`, `endTime` |
| `listen_data_today_song` | 听歌足迹 - 今日收听 | `/api/content/activity/listen/data/today/song/play/rank` | — | — |
| `listen_data_total` | 听歌足迹 - 总收听时长 | `/api/content/activity/listen/data/total` | — | — |
| `listen_data_year_report` | 听歌足迹 - 年度听歌足迹 | `/api/content/activity/listen/data/year/report` | — | — |
| `middle_play_do_lottery` | 云小编每日抽奖 | `/api/middle/play/do/lottery` | — | `activityId`, `drawCount` |
| `middle_play_lottery_remain_chance` | 云小编抽奖剩余次数查询 | `/api/middle/play/lottery/remain/chance` | — | `activityId` |
| `music_first_listen_info` | 回忆坐标 | `/api/content/activity/music/first/listen/info` | `id` | — |
| `radio_sport_get` | 跑步漫游 | `/api/radio/sport/get` | — | `bpm` |
| `recent_listen_list` | 最近听歌列表 | `/api/pc/recent/listen/list` | — | — |
| `record_recent_album` | — | `/api/play-record/album/list` | — | `limit` |
| `record_recent_dj` | — | `/api/play-record/djradio/list` | — | `limit` |
| `record_recent_song` | — | `/api/play-record/song/list` | — | `limit` |
| `record_recent_video` | — | `/api/play-record/newvideo/list` | — | `limit` |
| `record_recent_voice` | — | `/api/play-record/voice/list` | — | `limit` |
| `relay_play_state_submit` | 提交歌曲播放状态 | `/api/relay/play/state/submit` | `id` | `sessionId`, `progress`, `playMode`, `type` |
| `scrobble` | 听歌打卡 | `/api/feedback/weblog` | `id`, `sourceid`, `time` | — |
| `scrobble_v1` | 听歌打卡 - NCBL 加密版 (仿桌面客户端 PLV/PLD 上报) | `NCBL 加密上报(本地构造)` | `id`, `time` | `total`, `sourceid`, `sourceId`, `source`, `name`, `artist`, `bitrate`, `level`, `vip` |
| `starpick_comments_summary` | 云村星评馆 - 简要评论列表 | `/api/homepage/block/page` | — | — |
| `summary_annual` | 年度听歌报告2017-2023 | `/api/activity/summary/annual/{year}/{userdata 或 data}` | `year` | — |
| `weblog` | 操作记录 | `/api/feedback/weblog` | `index` | `data` |

---

## 附录 B:枚举速查

摘自上游 `interface.d.ts`。

### `SearchType`(搜索类型)

| 值 | 含义 | 值 | 含义 |
| --- | --- | --- | --- |
| `1` | 单曲 | `1004` | MV |
| `10` | 专辑 | `1006` | 歌词 |
| `100` | 歌手 | `1009` | 电台 |
| `1000` | 歌单 | `1014` | 视频 |
| `1002` | 用户 | `1018` | 综合 |

### `SoundQualityType`(音质等级,`song_url_v1` 的 `level`)

| 值 | 含义 | 值 | 含义 |
| --- | --- | --- | --- |
| `standard` | 标准 | `hires` | Hi-Res |
| `exhigh` | 极高 | `jyeffect` | 高清环绕声 |
| `lossless` | 无损 | `jymaster` | 超清母带 |
| `sky` | 沉浸环绕声 | `vivid` | vivid |

> 项目 UI 额外提供了 `higher`(较高),上游枚举未列但实际可用。

### `UserRecordType`(`user_record` 的 `type`)

| 值 | 含义 |
| --- | --- |
| `0` | 全部 |
| `1` | 本周 |
