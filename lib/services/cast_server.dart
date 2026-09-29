import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Lightweight HTTP server that serves local audio files over the LAN
/// so a Google Cast device can stream them.
///
/// Uses plain HTTP (not HTTPS) because the Google Cast protocol requires
/// the receiver to fetch media over the local network, and Cast devices
/// do not validate TLS certificates for LAN addresses. Because the transport
/// is cleartext, access control is layered:
///
/// * requests from anything other than a loopback/RFC1918/link-local peer are
///   refused, so a server reachable via a public or tethered interface still
///   cannot be used from off the LAN;
/// * a per-session random token is embedded in all URLs;
/// * the token is compared without an early exit;
/// * the server shuts itself down once it has been idle for [idleTimeout],
///   so a session that ends without an explicit stop (receiver lost, app
///   killed mid-cast) does not keep streaming indefinitely.
///
/// Requests that fail any check all return 404 with no body, so a prober
/// cannot distinguish "bad token" from "bad path".
class CastServer {
  HttpServer? _server;

  /// Files currently being served, indexed by list position.
  List<String> _files = [];

  /// Optional cover image path served at `/cover/<token>`.
  String? _coverPath;

  /// Per-session random token embedded in all served URLs.
  /// Requests without this token are rejected with 404.
  String _sessionToken = '';

  /// The current session token (empty string when server is not running).
  String get sessionToken => _sessionToken;

  /// Whether the server is running.
  bool get isRunning => _server != null;

  /// Auto-shutdown delay after the last request. Playback keeps the receiver
  /// issuing range requests continuously, so anything this long without a
  /// single request means the session is over.
  @visibleForTesting
  static Duration idleTimeout = const Duration(minutes: 5);

  /// Ceiling on simultaneously-served requests, so a single peer cannot
  /// exhaust the process's sockets or file descriptors.
  static const int maxConnections = 8;

  Timer? _idleTimer;
  int _activeConnections = 0;

  /// Start serving [audioFiles] and return the base URL
  /// (e.g. `http://192.168.1.5:8080`).
  ///
  /// Audio files are available at `<baseUrl>/audio/<index>`.
  /// Cover art (if provided) is at `<baseUrl>/cover`.
  Future<String> start(List<String> audioFiles, {String? coverPath}) async {
    // Never serve two sessions at once — a leaked prior server would keep
    // serving stale content under an old token.
    await stop();
    _files = audioFiles;
    _coverPath = coverPath;
    _sessionToken = _randomToken();

    final ip = await _localIp();
    // Bound to all interfaces: receivers may sit on a different local
    // subnet/NIC than the one _localIp() picks, and restricting the bind can
    // silently break delivery. Access control rests on the peer-address check
    // in _handleRequest plus the 128-bit session token in the URL path.
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    final port = _server!.port;
    // Token intentionally NOT logged — it gates access to the user's files.
    debugPrint('[Kowhai:CastServer] Serving ${_files.length} file(s) on $ip:$port');

    _armIdleTimeout();
    _server!.listen((request) {
      if (_activeConnections >= maxConnections) {
        request.response
          ..statusCode = HttpStatus.serviceUnavailable
          ..close();
        return;
      }
      _activeConnections++;
      // Decrement on completion, however the handler exits.
      _handleRequest(request).whenComplete(() => _activeConnections--);
    });
    return 'http://$ip:$port';
  }

  void _armIdleTimeout() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, () {
      debugPrint('[Kowhai:CastServer] idle timeout — shutting down');
      unawaited(stop());
    });
  }

  Future<void> stop() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    _activeConnections = 0;
    await _server?.close(force: true);
    _server = null;
    _files = [];
    _coverPath = null;
    _sessionToken = '';
  }

  // ── Request handling ──────────────────────────────────────────────────────

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;

      // Refuse peers that are not on this device's LAN. A Google Cast
      // receiver is always local, so this only ever excludes hosts that have
      // no business streaming the user's audiobooks.
      if (!isLocalNetwork(request.connectionInfo?.remoteAddress)) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..close();
        return;
      }

      // Any valid request means the session is live; defer the auto-shutdown.
      _armIdleTimeout();

      // All valid paths begin with the session token.
      if (segments.isEmpty || !_tokenMatches(segments[0])) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..close();
        return;
      }

      if (segments.length == 3 && segments[1] == 'audio') {
        final index = int.tryParse(segments[2]);
        if (index != null && index >= 0 && index < _files.length) {
          await _serveFile(request, _files[index]);
          return;
        }
      }

      if (segments.length == 2 && segments[1] == 'cover' && _coverPath != null) {
        await _serveFile(request, _coverPath!);
        return;
      }

      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
    } catch (e) {
      debugPrint('[CastServer] Error handling request: $e');
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..close();
      } catch (_) {}
    }
  }

  /// Serve a local file, supporting HTTP range requests for seeking.
  Future<void> _serveFile(HttpRequest request, String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
      return;
    }

    final length = await file.length();
    final contentType = mimeType(filePath);
    final response = request.response;

    // Parse Range header for partial content (required for seeking).
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null) {
      final parsed = parseByteRange(rangeHeader, length);
      if (parsed == null) {
        // RFC 7233: invalid / unsatisfiable range → 416 with Content-Range: */<length>.
        response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        await response.close();
        return;
      }
      final (start, end) = parsed;

      response
        ..statusCode = HttpStatus.partialContent
        ..headers.contentType = ContentType.parse(contentType)
        ..headers.contentLength = end - start + 1
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..headers.set(
            HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');

      await response.addStream(file.openRead(start, end + 1));
      await response.close();
    } else {
      response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.parse(contentType)
        ..headers.contentLength = length
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

      await response.addStream(file.openRead());
      await response.close();
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static String mimeType(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.mp3':
        return 'audio/mpeg';
      case '.m4a':
      case '.m4b':
      case '.mp4':
        return 'audio/mp4';
      case '.ogg':
      case '.opus':
        return 'audio/ogg';
      case '.flac':
        return 'audio/flac';
      case '.wav':
        return 'audio/wav';
      case '.aac':
        return 'audio/aac';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.png':
        return 'image/png';
      default:
        return 'application/octet-stream';
    }
  }

  /// Parses an HTTP `Range` header into `(start, end)` inclusive byte offsets,
  /// or returns `null` if the header is malformed or unsatisfiable for a file
  /// of [length] bytes. Only single-range `bytes=start-end` and open-ended
  /// `bytes=start-` forms are supported.
  static (int, int)? parseByteRange(String header, int length) {
    if (!header.startsWith('bytes=')) return null;
    if (length <= 0) return null;
    final rangeStr = header.substring(6);
    // Multi-range not supported.
    if (rangeStr.contains(',')) return null;
    final parts = rangeStr.split('-');
    if (parts.length != 2) return null;
    final start = int.tryParse(parts[0]);
    if (start == null || start < 0) return null;
    final end = parts[1].isEmpty ? length - 1 : int.tryParse(parts[1]);
    if (end == null || end < start) return null;
    if (start >= length) return null;
    final clampedEnd = end >= length ? length - 1 : end;
    return (start, clampedEnd);
  }

  static String _randomToken() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Compares [candidate] against the session token without an early exit.
  ///
  /// The token is the only thing gating the user's audiobooks, and a plain
  /// `!=` bails on the first differing byte, leaking the correct prefix
  /// through response timing. Length is folded into the accumulator so the
  /// compare loop's trip count carries no information either.
  bool _tokenMatches(String candidate) {
    final a = utf8.encode(candidate);
    final b = utf8.encode(_sessionToken);
    var diff = a.length == b.length ? 0 : 1;
    final n = min(a.length, b.length);
    for (var i = 0; i < n; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// True when [address] is loopback, RFC1918 private, or link-local — i.e. a
  /// host on the same LAN. Everything else is refused.
  @visibleForTesting
  static bool isLocalNetwork(InternetAddress? address) {
    if (address == null) return false;
    if (address.isLoopback) return true;
    final v4 = _asIpv4(address);
    if (v4 != null) return _isPrivateV4(v4);
    return _isPrivateV6(address.rawAddress);
  }

  /// Maps an IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) to its 4 bytes, or
  /// returns null when [address] is not IPv4-shaped.
  static List<int>? _asIpv4(InternetAddress address) {
    final b = address.rawAddress;
    if (b.length == 4) return b;
    if (b.length == 16) {
      for (var i = 0; i < 10; i++) {
        if (b[i] != 0) return null;
      }
      if (b[10] != 0xFF || b[11] != 0xFF) return null;
      return b.sublist(12);
    }
    return null;
  }

  static bool _isPrivateV4(List<int> b) {
    if (b.length != 4) return false;
    if (b[0] == 10) return true;                                  // 10.0.0.0/8
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;     // 172.16.0.0/12
    if (b[0] == 192 && b[1] == 168) return true;                  // 192.168.0.0/16
    if (b[0] == 169 && b[1] == 254) return true;                  // 169.254.0.0/16
    return false;
  }

  static bool _isPrivateV6(List<int> b) {
    if (b.length != 16) return false;
    if ((b[0] & 0xFE) == 0xFC) return true;                       // fc00::/7
    if (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) return true;       // fe80::/10
    return false;
  }

  static Future<String> _localIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }
}
