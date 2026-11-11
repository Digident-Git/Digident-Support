// Digident Support - promotional banner and update notice.
//
// Reads a small JSON file from ONE fixed HTTPS address and shows dismissible cards on the
// home page. Nothing is downloaded or installed automatically: buttons only open a link in
// the default browser. All failures (no internet, bad file) are silent.
// The card shows on every start until banner.json says "enabled": false; the file is
// re-read at start-up and every 30 minutes.
//
// The placeholders __DG_BANNER_URL__ and __DG_VERSION__ are filled in by the build workflow.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

const String _kBannerUrl = '__DG_BANNER_URL__';
const String _kAppVersion = '__DG_VERSION__';
const Color _kOrange = Color(0xFFE07510);

class DigidentBanner extends StatefulWidget {
  const DigidentBanner({Key? key}) : super(key: key);

  @override
  State<DigidentBanner> createState() => _DigidentBannerState();
}

class _BannerData {
  final String id;
  final String title;
  final String text;
  final String buttonText;
  final String? imageUrl;
  final String? linkUrl;
  final double aspect;
  final bool wide;

  const _BannerData({
    required this.id,
    required this.title,
    required this.text,
    required this.buttonText,
    this.imageUrl,
    this.linkUrl,
    this.aspect = 4.0,
    this.wide = false,
  });
}

class _DigidentBannerState extends State<DigidentBanner> {
  _BannerData? _banner;
  _BannerData? _update;
  final Set<String> _dismissed = <String>{};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (!_kBannerUrl.startsWith('https://')) return;
    _run();
  }

  int _fails = 0;

  // After a failure: retry after 20 s, 1 min, 5 min; then every 30 min (also when it works).
  void _schedule() {
    _timer?.cancel();
    Duration d;
    if (_fails == 1) {
      d = const Duration(seconds: 20);
    } else if (_fails == 2) {
      d = const Duration(minutes: 1);
    } else if (_fails == 3) {
      d = const Duration(minutes: 5);
    } else {
      d = const Duration(minutes: 30);
    }
    _timer = Timer(d, _run);
  }

  Future<void> _run() async {
    final result = await _refresh();
    _fails = result.startsWith('OK') ? 0 : _fails + 1;
    await _writeStatus(result);
    if (mounted) _schedule();
  }

  // Diagnostic file: %AppData%\Digident Support\banner-status.txt (stays on this computer).
  Future<void> _writeStatus(String msg) async {
    try {
      final appData = Platform.environment['APPDATA'];
      if (appData == null || appData.isEmpty) return;
      final dir = Directory(appData + '\\Digident Support');
      if (!await dir.exists()) await dir.create(recursive: true);
      await File(dir.path + '\\banner-status.txt').writeAsString(
          DateTime.now().toIso8601String() +
              '\nversion ' +
              _kAppVersion +
              '\n' +
              msg +
              '\n');
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // Only https links to Digident, to the banner host itself, or to the Digident GitHub.
  bool _hostAllowed(Uri u) {
    if (u.scheme != 'https') return false;
    final h = u.host.toLowerCase();
    if (h == 'digident.gr' || h.endsWith('.digident.gr')) return true;
    final base = Uri.tryParse(_kBannerUrl);
    if (base != null && h == base.host.toLowerCase()) return true;
    if (h == 'github.com' && u.path.startsWith('/Digident-Git/')) return true;
    return false;
  }

  String? _safeUrl(dynamic v) {
    if (v is! String) return null;
    final u = Uri.tryParse(v.trim());
    if (u == null || !_hostAllowed(u)) return null;
    return u.toString();
  }

  String _str(dynamic v, int max) {
    if (v is! String) return '';
    final s = v.trim();
    return s.length > max ? s.substring(0, max) : s;
  }

  List<int> _parseVersion(String s) {
    final out = <int>[];
    for (final p in s.split('.')) {
      out.add(int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0);
    }
    while (out.length < 3) {
      out.add(0);
    }
    return out;
  }

  bool _isNewer(String latest, String current) {
    final a = _parseVersion(latest);
    final b = _parseVersion(current);
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }

  Future<String> _refresh() async {
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);
      final uri = Uri.parse(_kBannerUrl).replace(queryParameters: {
        't': DateTime.now().millisecondsSinceEpoch.toString(),
      });
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 15));
      req.headers.set('Accept', 'application/json');
      req.headers.set('Cache-Control', 'no-cache');
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return 'HTTP ' + resp.statusCode.toString();
      final body = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
      if (body.length > 20000) return 'file too large';
      final data = jsonDecode(body);
      if (data is! Map) return 'unexpected file format';

      _BannerData? banner;
      final b = data['banner'];
      if (b is Map && b['enabled'] == true) {
        final id = _str(b['id'], 64);
        final text = _str(b['text'], 400);
        final img = _safeUrl(b['image_url']);
        final layout = _str(b['layout'], 16).toLowerCase();
        final a = b['image_aspect'];
        final aspect = (a is num && a >= 1 && a <= 8) ? a.toDouble() : 4.0;
        if (id.isNotEmpty && (text.isNotEmpty || img != null)) {
          banner = _BannerData(
            id: id,
            title: _str(b['title'], 120),
            text: text,
            buttonText: _str(b['button_text'], 40),
            imageUrl: img,
            linkUrl: _safeUrl(b['url']),
            aspect: aspect,
            wide: img != null && layout != 'card',
          );
        }
      }

      _BannerData? update;
      final u = data['update'];
      if (u is Map) {
        final latest = _str(u['latest_version'], 32);
        final link = _safeUrl(u['download_url']);
        if (latest.isNotEmpty && link != null && _isNewer(latest, _kAppVersion)) {
          update = _BannerData(
            id: 'update-' + latest,
            title: 'Διαθέσιμη νέα έκδοση ' + latest,
            text: _str(u['notes'], 300),
            buttonText: 'Λήψη',
            linkUrl: link,
          );
        }
      }

      if (!mounted) return 'OK (window closed)';
      setState(() {
        _banner = banner;
        _update = update;
      });
      return 'OK (banner: ' +
          (banner != null ? 'on' : 'off') +
          ', update: ' +
          (update != null ? 'on' : 'off') +
          ')';
    } catch (e) {
      // No message on screen on purpose; the reason goes to banner-status.txt.
      final m = e.runtimeType.toString() + ': ' + e.toString();
      return m.length > 300 ? m.substring(0, 300) : m;
    } finally {
      client?.close(force: true);
    }
  }

  // Closing a card hides it only until the program is opened again.
  void _dismiss(String id) {
    setState(() {
      _dismissed.add(id);
    });
  }

  Future<void> _open(String? url) async {
    if (url == null) return;
    try {
      await launchUrlString(url);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final cards = <Widget>[];
    final u = _update;
    if (u != null && !_dismissed.contains(u.id)) {
      cards.add(_card(context, u));
    }
    final b = _banner;
    if (b != null && !_dismissed.contains(b.id)) {
      cards.add(_card(context, b));
    }
    if (cards.isEmpty) return const SizedBox.shrink();
    return Column(mainAxisSize: MainAxisSize.min, children: cards);
  }

  // Full-width clickable image. It grows with the window (up to 1200 px wide) and is
  // limited to 30% of the window height, keeping its aspect ratio (default 4:1).
  Widget _wide(BuildContext context, _BannerData d) {
    return LayoutBuilder(builder: (context, constraints) {
      final paneW =
          constraints.maxWidth.isFinite ? constraints.maxWidth : 900.0;
      final winH = MediaQuery.of(context).size.height;
      double w = paneW - 24;
      if (w > 1200) w = 1200;
      final maxH = winH * 0.30;
      if (w / d.aspect > maxH) w = maxH * d.aspect;
      if (w < 120) return const SizedBox.shrink();
      final h = w / d.aspect;
      final image = Image.network(
        d.imageUrl!,
        width: w,
        height: h,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (c, e, s) => const SizedBox.shrink(),
      );
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
        child: Center(
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: d.linkUrl == null
                    ? image
                    : MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          onTap: () => _open(d.linkUrl),
                          child: image,
                        ),
                      ),
              ),
              Positioned(
                top: 6,
                right: 6,
                child: Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _dismiss(d.id),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close, size: 16, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _card(BuildContext context, _BannerData d) {
    if (d.wide) return _wide(context, d);
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: _kOrange, width: 1.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (d.imageUrl != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  d.imageUrl!,
                  width: 240,
                  height: 80,
                  fit: BoxFit.cover,
                  errorBuilder: (c, e, s) => const SizedBox.shrink(),
                ),
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (d.title.isNotEmpty)
                  Text(
                    d.title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                if (d.text.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      d.text,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (d.linkUrl != null && d.buttonText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _kOrange,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () => _open(d.linkUrl),
                      child: Text(d.buttonText),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Κλείσιμο',
            onPressed: () => _dismiss(d.id),
          ),
        ],
      ),
    );
  }
}
