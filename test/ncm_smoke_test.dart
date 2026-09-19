// SPDX-License-Identifier: MIT
//
// End-to-end smoke test for the new NCM API Enhanced integration.
//
// Replaces the old `worker_smoke_test.dart` which depended on
// ApiClient + ApiWorker (the worker-isolate RPC layer that's gone).
// We test:
//   - NcmApi.start() (spawn node + connect NDJSON)
//   - A real upstream NCM call (search)
//   - MusicResponse adapter shape
//
// Run from project root:
//   NCM_BRIDGE_ROOT=$PWD/build/ncm_bridge \
//   flutter test test/ncm_smoke_test.dart --timeout=5x

import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:ncm_api_enhanced/ncm_api_enhanced.dart';
import 'package:oceanus/sdk/MethodSpec.dart';
import 'package:oceanus/sdk/MusicResponse.dart';

void main() {
  final root = Platform.environment['NCM_BRIDGE_ROOT'];
  if (root == null || root.isEmpty) {
    test('bridge smoke', () {
      markTestSkipped(
        'NCM_BRIDGE_ROOT not set. Run '
        '`rsync -aL --delete --ignore-times '
        '\$NCM_API_ENHANCED/bridge/ build/ncm_bridge/` first.',
      );
    });
    return;
  }

  TestWidgetsFlutterBinding.ensureInitialized();

  late NcmApi api;
  setUp(() async {
    api = NcmApi(bridge: DesktopNcmBridge(bridgeRoot: root));
    await api.start();
  });

  tearDown(() async {
    await api.shutdown();
  });

  test('start() emits the ready event', () async {
    expect(api, isNotNull);
    // start() already awaited "ready" in setUp; if we get here without
    // throwing, the bridge is up.
  });

  test('positional → query translation works for a known method', () {
    // Pure function; no API call needed.
    final query = positionalToQuery('search', <Object?>['周杰伦', '1', '3']);
    expect(query['keywords'], '周杰伦');
    expect(query['type'], '1');
    expect(query['limit'], '3');
  });

  test('positionalToQuery fills defaults for missing args', () {
    final query = positionalToQuery('album_sublist', <Object?>[]);
    expect(query['limit'], '50');
  });

  test('MusicResponse.fromNcm parses upstream payload', () {
    final m = MusicResponse.fromNcm({
      'status': 200,
      'body': {
        'code': 200,
        'result': {'songs': []},
      },
      'cookie': ['NMTID=foo; Path=/;', 'MUSIC_U=bar; Path=/;'],
    });
    expect(m.status, 200);
    expect(m.body['code'], 200);
    expect(m.cookies, contains('NMTID=foo'));
    expect(m.cookies, contains('MUSIC_U=bar'));
  });

  test('search round-trip', () async {
    final sw = Stopwatch()..start();
    final raw = await api.call('search', <String, dynamic>{
      'keywords': '周杰伦',
      'type': '1',
      'limit': '3',
    });
    sw.stop();
    final r = MusicResponse.fromNcm(raw);
    // ignore: avoid_print
    print('search: ${sw.elapsedMilliseconds}ms, status=${r.status}');
    expect(r.status, 200);
    expect(r.body['code'], 200);
    final songs = (r.body['result']?['songs'] as List?) ?? [];
    expect(songs, isNotEmpty, reason: 'search for 周杰伦 should return songs');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
