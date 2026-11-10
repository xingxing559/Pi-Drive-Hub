import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pi_pan/providers/baidu_client/baidu_client_api.dart';
import 'package:pi_pan/providers/baidu_client/baidu_client_auth.dart';
import 'package:pi_pan/providers/quark/quark_api.dart';
import 'package:pi_pan/providers/quark/quark_auth.dart';
import 'package:pi_pan/providers/pan123/pan123_api.dart';
import 'package:pi_pan/providers/pan123/pan123_auth.dart';

class OfflinePan123Auth extends Pan123AuthProvider {
  @override
  Future<String?> getAccessToken() async => 'offline-test-placeholder';
}

void main() {
  test('Baidu listing sends start/limit and includes page two', () async {
    final offsets = <int>[];
    final client = MockClient((request) async {
      expect(request.url.queryParameters['dir'], '/资料');
      expect(request.url.queryParameters['method'], 'list');
      expect(request.url.queryParameters['limit'], '1000');
      final start = int.parse(request.url.queryParameters['start']!);
      offsets.add(start);
      final count = start == 0 ? 1000 : 2;
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'errno': 0,
            'list': List.generate(
              count,
              (i) => {'fs_id': start + i, 'path': '/资料/${start + i}'},
            ),
          }),
        ),
        200,
      );
    });
    final api = BaiduClientApi(auth: BaiduClientAuthProvider(), client: client);
    final result = await api.listDir('/资料');
    expect(result.length, 1002);
    expect(result.last['path'], '/资料/1001');
    expect(offsets, [0, 1000]);
    client.close();
  });

  test(
    'Baidu pagination propagates page-two failure, not a partial success',
    () async {
      final client = MockClient((request) async {
        final offset = int.parse(request.url.queryParameters['start']!);
        if (offset > 0) return http.Response('{"errno":-9}', 200);
        return http.Response(
          jsonEncode({
            'errno': 0,
            'list': List.generate(1000, (i) => {'fs_id': i}),
          }),
          200,
        );
      });
      final api = BaiduClientApi(
        auth: BaiduClientAuthProvider(),
        client: client,
      );
      await expectLater(
        api.listDir('/docs'),
        throwsA(isA<BaiduClientApiException>()),
      );
      client.close();
    },
  );
  test('Quark follows pages even when total metadata is missing', () async {
    final pages = <String?>[];
    final client = MockClient((request) async {
      pages.add(request.url.queryParameters['_page']);
      final first = request.url.queryParameters['_page'] == '1';
      return http.Response(
        jsonEncode({
          'code': 0,
          'data': {
            'list':
                first
                    ? [
                      {'fid': '1'},
                      {'fid': '2'},
                    ]
                    : [
                      {'fid': '3'},
                    ],
          },
        }),
        200,
      );
    });
    final api = QuarkApi(auth: QuarkAuthProvider(), client: client);
    expect((await api.listDir('0', pageSize: 2)).length, 3);
    expect(pages, ['1', '2']);
    client.close();
  });

  test(
    '123 follows the returned cursor and accepts numeric end marker',
    () async {
      final pages = <String?>[];
      final cursors = <String?>[];
      final client = MockClient((request) async {
        final first = request.url.queryParameters['Page'] == '1';
        pages.add(request.url.queryParameters['Page']);
        cursors.add(request.url.queryParameters['next']);
        return http.Response(
          jsonEncode({
            'code': 0,
            'data': {
              'InfoList':
                  first
                      ? [
                        {'FileId': 1},
                        {'FileId': 2},
                      ]
                      : [
                        {'FileId': 3},
                      ],
              'Next': first ? 42 : -1,
            },
          }),
          200,
        );
      });
      final api = Pan123Api(auth: OfflinePan123Auth(), client: client);
      expect((await api.listDir(0, pageSize: 2)).length, 3);
      expect(pages, ['1', '2']);
      expect(cursors, ['0', '42']);
      client.close();
    },
  );
}
