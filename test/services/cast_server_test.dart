import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kowhai/services/cast_server.dart';

void main() {
  group('CastServer.parseByteRange', () {
    test('valid closed range', () {
      expect(CastServer.parseByteRange('bytes=0-99', 1000), (0, 99));
      expect(CastServer.parseByteRange('bytes=100-199', 1000), (100, 199));
    });

    test('open-ended range clamps to last byte', () {
      expect(CastServer.parseByteRange('bytes=500-', 1000), (500, 999));
    });

    test('end beyond length is clamped to length-1', () {
      expect(CastServer.parseByteRange('bytes=0-99999', 1000), (0, 999));
    });

    test('missing bytes= prefix is rejected', () {
      expect(CastServer.parseByteRange('0-99', 1000), isNull);
      expect(CastServer.parseByteRange('items=0-99', 1000), isNull);
    });

    test('non-numeric start or end is rejected', () {
      expect(CastServer.parseByteRange('bytes=abc-99', 1000), isNull);
      expect(CastServer.parseByteRange('bytes=0-xyz', 1000), isNull);
    });

    test('negative start is rejected', () {
      expect(CastServer.parseByteRange('bytes=-100', 1000), isNull);
    });

    test('end before start is rejected', () {
      expect(CastServer.parseByteRange('bytes=500-100', 1000), isNull);
    });

    test('start beyond length is rejected (416)', () {
      expect(CastServer.parseByteRange('bytes=2000-3000', 1000), isNull);
      expect(CastServer.parseByteRange('bytes=1000-', 1000), isNull);
    });

    test('multi-range is not supported', () {
      expect(CastServer.parseByteRange('bytes=0-99,200-299', 1000), isNull);
    });

    test('empty file length rejects any range', () {
      expect(CastServer.parseByteRange('bytes=0-0', 0), isNull);
    });

    test('completely malformed header is rejected', () {
      expect(CastServer.parseByteRange('bytes=', 1000), isNull);
      expect(CastServer.parseByteRange('bytes=garbage', 1000), isNull);
      expect(CastServer.parseByteRange('', 1000), isNull);
    });
  });

  group('CastServer.mimeType', () {
    test('audio extensions', () {
      expect(CastServer.mimeType('song.mp3'), 'audio/mpeg');
      expect(CastServer.mimeType('song.M4B'), 'audio/mp4');
      expect(CastServer.mimeType('song.ogg'), 'audio/ogg');
      expect(CastServer.mimeType('song.flac'), 'audio/flac');
      expect(CastServer.mimeType('song.wav'), 'audio/wav');
      expect(CastServer.mimeType('song.aac'), 'audio/aac');
    });

    test('image extensions', () {
      expect(CastServer.mimeType('cover.jpg'), 'image/jpeg');
      expect(CastServer.mimeType('cover.JPEG'), 'image/jpeg');
      expect(CastServer.mimeType('cover.png'), 'image/png');
    });

    test('unknown extension falls back to octet-stream', () {
      expect(CastServer.mimeType('notes.txt'), 'application/octet-stream');
      expect(CastServer.mimeType('no-extension'), 'application/octet-stream');
    });
  });

  group('CastServer end-to-end', () {
    late Directory tempDir;
    late File audioFile;
    late File coverFile;
    late CastServer server;
    late Uri base;
    late String token;
    // Cast audio to 10 KB of predictable bytes for range math.
    final audioBytes = List<int>.generate(10240, (i) => i % 256);
    final coverBytes = List<int>.generate(512, (i) => (i * 7) % 256);

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cast_server_test_');
      audioFile = File('${tempDir.path}/track.mp3');
      coverFile = File('${tempDir.path}/cover.jpg');
      await audioFile.writeAsBytes(audioBytes);
      await coverFile.writeAsBytes(coverBytes);

      server = CastServer();
      final baseUrl = await server.start(
        [audioFile.path],
        coverPath: coverFile.path,
      );
      token = server.sessionToken;
      // The reported IP can be a LAN address; for tests, rewrite to localhost.
      final parsed = Uri.parse(baseUrl);
      base = Uri.parse('http://127.0.0.1:${parsed.port}');
    });

    tearDown(() async {
      await server.stop();
      await tempDir.delete(recursive: true);
    });

    test('GET /<token>/audio/0 returns full file with 200', () async {
      final resp = await http.get(base.resolve('/$token/audio/0'));
      expect(resp.statusCode, 200);
      expect(resp.headers['content-type'], 'audio/mpeg');
      expect(resp.headers['accept-ranges'], 'bytes');
      expect(resp.bodyBytes.length, audioBytes.length);
      expect(resp.bodyBytes, audioBytes);
    });

    test('GET /<token>/cover returns the cover file', () async {
      final resp = await http.get(base.resolve('/$token/cover'));
      expect(resp.statusCode, 200);
      expect(resp.headers['content-type'], 'image/jpeg');
      expect(resp.bodyBytes, coverBytes);
    });

    test('GET /<token>/audio/99 for missing index returns 404', () async {
      final resp = await http.get(base.resolve('/$token/audio/99'));
      expect(resp.statusCode, 404);
    });

    test('GET /unknown returns 404', () async {
      final resp = await http.get(base.resolve('/unknown/path'));
      expect(resp.statusCode, 404);
    });

    test('request without token returns 404', () async {
      final resp = await http.get(base.resolve('/audio/0'));
      expect(resp.statusCode, 404);
    });

    test('request with wrong token returns 404', () async {
      final resp = await http.get(base.resolve('/wrongtoken/audio/0'));
      expect(resp.statusCode, 404);
    });

    test('valid Range header returns 206 with correct slice', () async {
      final resp = await http.get(
        base.resolve('/$token/audio/0'),
        headers: {'Range': 'bytes=100-199'},
      );
      expect(resp.statusCode, 206);
      expect(resp.headers['content-range'], 'bytes 100-199/10240');
      expect(resp.bodyBytes.length, 100);
      expect(resp.bodyBytes, audioBytes.sublist(100, 200));
    });

    test('open-ended Range returns 206 to EOF', () async {
      final resp = await http.get(
        base.resolve('/$token/audio/0'),
        headers: {'Range': 'bytes=10000-'},
      );
      expect(resp.statusCode, 206);
      expect(resp.headers['content-range'], 'bytes 10000-10239/10240');
      expect(resp.bodyBytes, audioBytes.sublist(10000));
    });

    test('malformed Range returns 416 with Content-Range */length', () async {
      final resp = await http.get(
        base.resolve('/$token/audio/0'),
        headers: {'Range': 'bytes=abc-xyz'},
      );
      expect(resp.statusCode, 416);
      expect(resp.headers['content-range'], 'bytes */10240');
    });

    test('Range beyond file length returns 416', () async {
      final resp = await http.get(
        base.resolve('/$token/audio/0'),
        headers: {'Range': 'bytes=99999-'},
      );
      expect(resp.statusCode, 416);
    });

    test('two concurrent range requests both succeed', () async {
      final f1 = http.get(
        base.resolve('/$token/audio/0'),
        headers: {'Range': 'bytes=0-99'},
      );
      final f2 = http.get(
        base.resolve('/$token/audio/0'),
        headers: {'Range': 'bytes=5000-5099'},
      );
      final results = await Future.wait([f1, f2]);
      expect(results[0].statusCode, 206);
      expect(results[1].statusCode, 206);
      expect(results[0].bodyBytes, audioBytes.sublist(0, 100));
      expect(results[1].bodyBytes, audioBytes.sublist(5000, 5100));
    });

    test('sessionToken is cleared after stop()', () async {
      expect(server.sessionToken, isNotEmpty);
      await server.stop();
      expect(server.sessionToken, isEmpty);
    });

    test('new session generates a different token', () async {
      final firstToken = server.sessionToken;
      await server.stop();
      await server.start([audioFile.path]);
      expect(server.sessionToken, isNot(firstToken));
    });
  });

  group('CastServer.isLocalNetwork', () {
    test('accepts loopback', () {
      expect(CastServer.isLocalNetwork(InternetAddress('127.0.0.1')), isTrue);
      expect(CastServer.isLocalNetwork(InternetAddress('::1')), isTrue);
    });

    test('accepts RFC1918 private ranges', () {
      expect(CastServer.isLocalNetwork(InternetAddress('10.1.2.3')), isTrue);
      expect(CastServer.isLocalNetwork(InternetAddress('172.16.0.5')), isTrue);
      expect(CastServer.isLocalNetwork(InternetAddress('172.31.255.255')),
          isTrue);
      expect(CastServer.isLocalNetwork(InternetAddress('192.168.1.50')),
          isTrue);
    });

    test('accepts link-local', () {
      expect(CastServer.isLocalNetwork(InternetAddress('169.254.10.1')),
          isTrue);
    });

    test('rejects public addresses', () {
      expect(CastServer.isLocalNetwork(InternetAddress('8.8.8.8')), isFalse);
      expect(CastServer.isLocalNetwork(InternetAddress('1.1.1.1')), isFalse);
      // 172.15 and 172.32 sit just outside 172.16.0.0/12.
      expect(CastServer.isLocalNetwork(InternetAddress('172.15.0.1')), isFalse);
      expect(CastServer.isLocalNetwork(InternetAddress('172.32.0.1')), isFalse);
      // 100.64.0.0/10 CGNAT is not RFC1918.
      expect(CastServer.isLocalNetwork(InternetAddress('100.64.0.1')), isFalse);
    });

    test('rejects IPv6 unique-local and link-local pass, global fails', () {
      expect(CastServer.isLocalNetwork(InternetAddress('fd00::1')), isTrue);
      expect(CastServer.isLocalNetwork(InternetAddress('fe80::1')), isTrue);
      expect(CastServer.isLocalNetwork(InternetAddress('2606:4700::1')),
          isFalse);
    });

    test('maps IPv4-mapped IPv6 back to the v4 rules', () {
      expect(CastServer.isLocalNetwork(InternetAddress('::ffff:192.168.0.1')),
          isTrue);
      expect(CastServer.isLocalNetwork(InternetAddress('::ffff:8.8.8.8')),
          isFalse);
    });

    test('null address is rejected', () {
      expect(CastServer.isLocalNetwork(null), isFalse);
    });
  });

  group('CastServer idle auto-shutdown', () {
    test('server stops itself after the idle timeout', () async {
      final idleServer = CastServer();
      final dir = await Directory.systemTemp.createTemp('cast_idle');
      final file = File('${dir.path}/a.mp3');
      await file.writeAsBytes(List.filled(2048, 0));
      addTearDown(() async {
        await idleServer.stop();
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });

      final prev = CastServer.idleTimeout;
      CastServer.idleTimeout = const Duration(milliseconds: 120);
      addTearDown(() => CastServer.idleTimeout = prev);

      await idleServer.start([file.path]);
      expect(idleServer.isRunning, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      // A session that ends without an explicit stop must not keep streaming.
      expect(idleServer.isRunning, isFalse);
      expect(idleServer.sessionToken, isEmpty);
    });

    test('active requests keep the server alive', () async {
      final liveServer = CastServer();
      final dir = await Directory.systemTemp.createTemp('cast_alive');
      final file = File('${dir.path}/a.mp3');
      await file.writeAsBytes(List.filled(2048, 0));
      addTearDown(() async {
        await liveServer.stop();
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });

      final prev = CastServer.idleTimeout;
      CastServer.idleTimeout = const Duration(milliseconds: 150);
      addTearDown(() => CastServer.idleTimeout = prev);

      final base = Uri.parse(await liveServer.start([file.path]));
      final token = liveServer.sessionToken;

      // Poll faster than the idle window; the timer must keep being deferred.
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        final r = await http.get(base.resolve('/$token/audio/0'));
        expect(r.statusCode, 200);
      }
      expect(liveServer.isRunning, isTrue);
    });
  });
}
