// Digident Support - promotional banner and update notice.
//
// Reads a small JSON file from ONE fixed HTTPS address and shows dismissible cards on the
// home page. Nothing is downloaded or installed automatically: buttons only open a link in
// the default browser. All failures (no internet, bad file) are silent.
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

  const _BannerData({
    required this.id,
    required this.title,
    required this.text,
    required this.buttonText,
    this.imageUrl,
    this.linkUrl,
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
    _loadDismissed();
    _refresh();
    _timer = Timer.periodic(const Duration(hours: 3), (_) => _refresh());
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

  Future<void> _refresh() async {
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 8);
      final req = await client
          .getUrl(Uri.parse(_kBannerUrl))
          .timeout(const Duration(seconds: 10));
      req.headers.set('Accept', 'application/json');
      final resp = await req.close().timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return;
      final body = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 10));
      if (body.length > 20000) return;
      final data = jsonDecode(body);
      if (data is! Map) return;

      _BannerData? banner;
      final b = data['banner'];
      if (b is Map && b['enabled'] == true) {
        final id = _str(b['id'], 64);
        final text = _str(b['text'], 400);
        if (id.isNotEmpty && text.isNotEmpty) {
          banner = _BannerData(
            id: id,
            title: _str(b['title'], 120),
            text: text,
            buttonText: _str(b['button_text'], 40),
            imageUrl: _safeUrl(b['image_url']),
            linkUrl: _safeUrl(b['url']),
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

      if (!mounted) return;
      setState(() {
        _banner = banner;
        _update = update;
      });
    } catch (_) {
      // Silent on purpose.
    } finally {
      client?.close(force: true);
    }
  }

  File? _dismissFile() {
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) return null;
    return File(appData + '\\Digident Support\\banner-dismissed.txt');
  }

  Future<void> _loadDismissed() async {
    try {
      final f = _dismissFile();
      if (f == null || !await f.exists()) return;
      final lines = await f.readAsLines();
      if (!mounted) return;
      setState(() {
        _dismissed.addAll(
            lines.map((e) => e.trim()).where((e) => e.isNotEmpty).take(200));
      });
    } catch (_) {}
  }

  Future<void> _dismiss(String id) async {
    setState(() {
      _dismissed.add(id);
    });
    try {
      final f = _dismissFile();
      if (f == null) return;
      await f.writeAsString(_dismissed.join('\n'));
    } catch (_) {}
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

  Widget _card(BuildContext context, _BannerData d) {
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
