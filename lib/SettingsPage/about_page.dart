import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/default.dart';

/// 关于页(静态内容):版本号 / 开源协议 / 源码仓库 / 联系方式。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static const repositoryUrl = 'https://github.com/cmachsocket/oceanus';
  static const aboutUrl = 'https://www.cmach.top';
  static const authorUrl = 'https://github.com/cmachsocket';

  /// 版本号在运行时从平台读取,改 pubspec.yaml 的 version 即生效。
  static final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Get.back(id: DefaultValues.shellNavigatorId),
        ),
        title: const Text('关于'),
      ),
      body: FutureBuilder<PackageInfo>(
        future: _packageInfo,
        builder: (context, snapshot) {
          final info = snapshot.data;
          return ListView(
            children: [
              Align(
                alignment: Alignment.center,
                child: ListTile(
                  leading: Image.asset('assets/oceanus.png'),
                  title: Text(
                    'Oceanus',
                    style: textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  subtitle: Text(
                    'Flutter 网易云音乐客户端',
                    style: textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.tag),
                title: const Text('版本号'),
                trailing: Text(info == null ? '…' : _versionLabel(info)),
              ),
              ListTile(
                leading: const Icon(Icons.article_outlined),
                title: const Text('开源协议'),
                subtitle: const Text('GNU General Public License v3.0'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Get.to(
                  () => LicensePage(
                    applicationName: 'Oceanus',
                    applicationVersion: info?.version,
                  ),
                  id: DefaultValues.shellNavigatorId,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.code),
                title: const Text('源码仓库'),
                subtitle: const Text(repositoryUrl),
                trailing: const Icon(Icons.copy),
                onTap: () => _copy(repositoryUrl),
              ),
              ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: const Text('关于我'),
                subtitle: const Text('cmach.top'),
                trailing: const Icon(Icons.copy),
                onTap: () => _copy(aboutUrl),
              ),
              ListTile(
                leading: const Icon(Icons.alternate_email),
                title: const Text('联系方式'),
                subtitle: const Text('GitHub @cmachsocket'),
                trailing: const Icon(Icons.copy),
                onTap: () => _copy(authorUrl),
              ),
              const Divider(),
              const ListTile(
                leading: Icon(Icons.volunteer_activism_outlined),
                title: Text('说明'),
                subtitle: Text('个人兴趣开发，非商业用途。如侵权请联系删除。'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// `1.4.2` + `1` → `1.4.2+1`;没有 buildNumber 时只显示版本号。
  static String _versionLabel(PackageInfo info) => info.buildNumber.isEmpty
      ? info.version
      : '${info.version}+${info.buildNumber}';

  /// 复制到剪贴板并提示 —— 不引入 url_launcher,避免为静态页加依赖。
  static Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    Get.snackbar('已复制', text, snackPosition: SnackPosition.BOTTOM);
  }
}
