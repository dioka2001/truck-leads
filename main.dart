import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

List<CameraDescription> _cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    _cameras = await availableCameras();
  } catch (_) {}
  runApp(const TruckLeadsApp());
}

class TruckLeadsApp extends StatelessWidget {
  const TruckLeadsApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Truck Leads',
        theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
        home: const ScanPage(),
      );
}

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------

class Hit {
  final DateTime time;
  final String company;
  final String country; // from the licence plate (blank if no plate was read)
  final String hint; // guess from the legal form in the name (SRL, KFT...)
  Hit(this.time, this.company, this.country, this.hint);
}

class _Found {
  final String text;
  final Rect box;
  _Found(this.text, this.box);
}

// ---------------------------------------------------------------------------
// Country knowledge
// ---------------------------------------------------------------------------

// International vehicle registration codes (the letters on the plate's
// blue strip or national oval). EU and non-EU European countries.
const Map<String, String> _stripCodes = {
  'A': 'Austria', 'AL': 'Albania', 'AND': 'Andorra', 'AM': 'Armenia',
  'AZ': 'Azerbaijan', 'B': 'Belgium', 'BG': 'Bulgaria',
  'BIH': 'Bosnia and Herzegovina', 'BY': 'Belarus', 'CH': 'Switzerland',
  'CY': 'Cyprus', 'CZ': 'Czechia', 'D': 'Germany', 'DK': 'Denmark',
  'E': 'Spain', 'EST': 'Estonia', 'F': 'France', 'FIN': 'Finland',
  'FL': 'Liechtenstein', 'GB': 'United Kingdom', 'GE': 'Georgia',
  'GR': 'Greece', 'H': 'Hungary', 'HR': 'Croatia', 'I': 'Italy',
  'IRL': 'Ireland', 'IS': 'Iceland', 'KS': 'Kosovo', 'L': 'Luxembourg',
  'LT': 'Lithuania', 'LV': 'Latvia', 'M': 'Malta', 'MC': 'Monaco',
  'MD': 'Moldova', 'MK': 'North Macedonia', 'MNE': 'Montenegro',
  'N': 'Norway', 'NL': 'Netherlands', 'P': 'Portugal', 'PL': 'Poland',
  'RO': 'Romania', 'RSM': 'San Marino', 'RUS': 'Russia', 'S': 'Sweden',
  'SK': 'Slovakia', 'SLO': 'Slovenia', 'SRB': 'Serbia', 'TR': 'Turkey',
  'UA': 'Ukraine',
};

// Fallback: plate formats that are distinctive enough to recognise without
// the country code. Extend this list with real samples from the road.
final List<MapEntry<String, RegExp>> _plateFormats = [
  MapEntry(
      'Romania',
      RegExp(
          r'^(AB|AG|AR|BC|BH|BN|BR|BT|BV|BZ|CJ|CL|CS|CT|CV|DB|DJ|GJ|GL|GR|HD|HR|IF|IL|IS|MH|MM|MS|NT|OT|PH|SB|SJ|SM|SV|TL|TM|TR|VL|VN|VS)\d{2}[A-Z]{3}$|^B\d{2,3}[A-Z]{3}$')),
  MapEntry('Bulgaria', RegExp(r'^[A-Z]{1,2}\d{4}[A-Z]{2}$')),
  MapEntry('Hungary', RegExp(r'^[A-Z]{3}\d{3}$')),
  MapEntry('Spain', RegExp(r'^\d{4}[BCDFGHJKLMNPRSTVWXYZ]{3}$')),
  MapEntry('France or Italy', RegExp(r'^[A-Z]{2}\d{3}[A-Z]{2}$')),
];

final RegExp _germanPlate =
    RegExp(r'^[A-ZÄÖÜ]{1,3}[\s\-]+[A-Z]{1,2}[\s\-]*\d{1,4}[EH]?$');

// Legal forms in the company name hint at the company's home country.
final List<MapEntry<RegExp, String>> _legalHints = [
  MapEntry(RegExp(r'\bKFT\b'), 'Hungary'),
  MapEntry(RegExp(r'\bZRT\b'), 'Hungary'),
  MapEntry(RegExp(r'\bSRL\b'), 'Romania/Italy/Moldova'),
  MapEntry(RegExp(r'\bGMBH\b'), 'Germany/Austria/Switzerland'),
  MapEntry(RegExp(r'\bSP Z OO\b'), 'Poland'),
  MapEntry(RegExp(r'\bDOO\b'), 'Balkans'),
  MapEntry(RegExp(r'\bSRO\b'), 'Czechia/Slovakia'),
  MapEntry(RegExp(r'\bEOOD\b'), 'Bulgaria'),
  MapEntry(RegExp(r'\bOOD\b'), 'Bulgaria'),
  MapEntry(RegExp(r'\bUAB\b'), 'Lithuania'),
  MapEntry(RegExp(r'\bSARL\b'), 'France'),
  MapEntry(RegExp(r'\bBV\b'), 'Netherlands'),
];

const _companyTokens = [
  'SRL', 'S.R.L', 'KFT', 'ZRT', 'GMBH', 'LTD', 'LLC', 'SP.Z',
  'TRANS', 'LOGISTIC', 'SPED', 'CARGO', 'EXPRESS',
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _alnum(String s) => s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

bool _looksLikeCompany(String t) {
  final u = t.toUpperCase();
  return _companyTokens.any(u.contains);
}

bool _keep(String t) {
  if (t.length < 4) return false;
  final letters = RegExp(r'\p{L}', unicode: true).allMatches(t).length;
  return letters / t.length >= 0.5;
}

bool _isContact(String t) {
  final u = t.toUpperCase();
  return u.contains('@') ||
      u.contains('WWW') ||
      u.contains('HTTP') ||
      u.contains('.COM') ||
      u.contains('.RO') ||
      u.contains('.HU') ||
      u.contains('.EU');
}

// A line that is exactly a country code, e.g. "RO" or "H".
String? _stripCountry(String raw) {
  final c = _alnum(raw);
  if (c.isEmpty || c.length > 3) return null;
  return _stripCodes[c];
}

// Capital letters and digits only, 5-9 characters, 2-5 digits: looks like a plate.
bool _plateLike(String raw) {
  if (raw != raw.toUpperCase()) return false;
  final c = _alnum(raw);
  if (c.length < 5 || c.length > 9) return false;
  final digits = RegExp(r'\d').allMatches(c).length;
  final letters = c.length - digits;
  return digits >= 2 && digits <= 5 && letters >= 2;
}

// Country from the plate text itself (used when no code is seen next to it).
String? _plateCountry(String raw) {
  final up = raw.toUpperCase().trim();
  if (_germanPlate.hasMatch(up)) return 'Germany';
  final c = _alnum(up);
  for (final f in _plateFormats) {
    if (f.value.hasMatch(c)) return f.key;
  }
  // Code and plate merged in one line, e.g. "RO BH 12 ABC".
  final m = RegExp(r'^([A-Z]{1,3})\s+(.+)$').firstMatch(up);
  if (m != null) {
    final country = _stripCodes[m.group(1)!];
    if (country != null && _plateLike(m.group(2)!)) return country;
  }
  return null;
}

String _legalHint(String t) {
  final u = t.toUpperCase().replaceAll('.', '').replaceAll(',', ' ');
  for (final h in _legalHints) {
    if (h.key.hasMatch(u)) return h.value;
  }
  return '';
}

// Turns one photo's recognised text into (company, country) rows.
List<Hit> _extractHits(RecognizedText result, DateTime now) {
  final all = <_Found>[];
  for (final block in result.blocks) {
    for (final line in block.lines) {
      final t = line.text.trim();
      if (t.isNotEmpty) all.add(_Found(t, line.boundingBox));
    }
  }

  // 1) country codes (blue strip letters)
  final strips = <MapEntry<Rect, String>>[];
  for (final f in all) {
    final c = _stripCountry(f.text);
    if (c != null) strips.add(MapEntry(f.box, c));
  }

  // 2) plates and their country (not stored, only used for the country)
  final plates = <MapEntry<Rect, String>>[];
  for (final f in all) {
    if (!_plateLike(f.text)) continue;
    String? country;
    double best = f.box.width * 1.2;
    for (final s in strips) {
      final d = (s.key.center - f.box.center).distance;
      if (d <= best) {
        best = d;
        country = s.value;
      }
    }
    country ??= _plateCountry(f.text);
    if (country != null) plates.add(MapEntry(f.box, country));
  }

  // 3) company name candidates
  final cands = <_Found>[];
  for (final f in all) {
    final t = f.text;
    if (!_keep(t) || _isContact(t)) continue;
    if (_plateLike(t) && !_looksLikeCompany(t)) continue;
    cands.add(f);
  }
  if (cands.isEmpty) return [];

  // keep only the large lettering, drop small print
  final maxH = cands.map((f) => f.box.height).reduce((a, b) => a > b ? a : b);

  final hits = <Hit>[];
  for (final f in cands) {
    if (f.box.height < maxH * 0.5) continue;
    String country = '';
    double best = double.infinity;
    for (final p in plates) {
      final d = (p.key.center - f.box.center).distance;
      if (d < best) {
        best = d;
        country = p.value;
      }
    }
    hits.add(Hit(now, f.text, country, _legalHint(f.text)));
  }
  return hits;
}

// ---------------------------------------------------------------------------
// UI
// ---------------------------------------------------------------------------

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  CameraController? _controller;
  final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final List<Hit> _hits = [];
  Timer? _timer;
  bool _busy = false;
  bool _scanning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    if (_cameras.isEmpty) {
      setState(() => _error = 'No camera found');
      return;
    }
    try {
      final desc = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );
      final c = CameraController(desc, ResolutionPreset.high,
          enableAudio: false);
      await c.initialize();
      await c.setFlashMode(FlashMode.off);
      if (!mounted) return;
      setState(() => _controller = c);
    } catch (e) {
      if (mounted) setState(() => _error = 'Camera error: $e');
    }
  }

  void _toggle() {
    if (_scanning) {
      _timer?.cancel();
    } else {
      _timer = Timer.periodic(
          const Duration(milliseconds: 1500), (_) => _scanOnce());
    }
    setState(() => _scanning = !_scanning);
  }

  Future<void> _scanOnce() async {
    final c = _controller;
    if (c == null || _busy || !c.value.isInitialized) return;
    _busy = true;
    try {
      final shot = await c.takePicture();
      final result =
          await _recognizer.processImage(InputImage.fromFilePath(shot.path));
      final fresh = _extractHits(result, DateTime.now());
      try {
        await File(shot.path).delete();
      } catch (_) {}
      if (mounted && fresh.isNotEmpty) {
        setState(() => _hits.insertAll(0, fresh));
      }
    } catch (_) {
      // ignore single-frame failures
    } finally {
      _busy = false;
    }
  }

  Future<void> _export() async {
    if (_hits.isEmpty) return;
    // Semicolon separator: opens correctly in Excel with HU/RO regional settings.
    final sb = StringBuffer('timestamp;company;plate_country;legal_form_hint\n');
    for (final h in _hits.reversed) {
      final name = h.company.replaceAll('"', '""');
      sb.writeln(
          '${h.time.toIso8601String()};"$name";${h.country};${h.hint}');
    }
    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/truck_leads_${DateTime.now().millisecondsSinceEpoch}.csv');
    await file.writeAsString('\uFEFF${sb.toString()}');
    await Share.shareXFiles([XFile(file.path)], text: 'Truck leads');
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller?.dispose();
    _recognizer.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    Widget preview;
    if (_error != null) {
      preview = Center(
          child: Padding(
              padding: const EdgeInsets.all(16), child: Text(_error!)));
    } else if (c == null) {
      preview = const Center(child: CircularProgressIndicator());
    } else {
      preview = Center(child: CameraPreview(c));
    }

    return Scaffold(
      appBar: AppBar(title: Text('Truck Leads (${_hits.length})')),
      body: Column(
        children: [
          Expanded(flex: 3, child: preview),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                FilledButton.icon(
                  onPressed: c == null ? null : _toggle,
                  icon: Icon(_scanning ? Icons.stop : Icons.play_arrow),
                  label: Text(_scanning ? 'Stop' : 'Start'),
                ),
                OutlinedButton.icon(
                  onPressed: _hits.isEmpty ? null : _export,
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Export CSV'),
                ),
                IconButton(
                  onPressed:
                      _hits.isEmpty ? null : () => setState(_hits.clear),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: ListView.builder(
              itemCount: _hits.length,
              itemBuilder: (_, i) {
                final h = _hits[i];
                final sub = <String>[
                  if (h.country.isNotEmpty) h.country,
                  if (h.country.isEmpty && h.hint.isNotEmpty)
                    '${h.hint} (name hint)',
                  h.time.toIso8601String().substring(11, 19),
                ].join(' \u00b7 ');
                return ListTile(
                  dense: true,
                  title: Text(h.company),
                  subtitle: Text(sub),
                  trailing: h.country.isNotEmpty ? const Icon(Icons.flag) : null,
                  onTap: () => Clipboard.setData(ClipboardData(
                      text: h.country.isEmpty
                          ? h.company
                          : '${h.company}, ${h.country}')),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
