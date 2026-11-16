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
// Text helpers
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

// --- similarity between two names (used for voting and for grouping) -------

int _lev(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0);
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      var v = prev[j] + 1;
      if (cur[j - 1] + 1 < v) v = cur[j - 1] + 1;
      if (prev[j - 1] + cost < v) v = prev[j - 1] + cost;
      cur[j] = v;
    }
    prev = cur;
  }
  return prev[b.length];
}

double _levRatio(String x, String y) {
  if (x.isEmpty || y.isEmpty) return 0;
  final longest = x.length > y.length ? x.length : y.length;
  return 1 - _lev(x, y) / longest;
}

double _sim(String a, String b) {
  final x = _alnum(a);
  final y = _alnum(b);
  if (x.isEmpty || y.isEmpty) return 0;
  double s = _levRatio(x, y);
  final shorter = x.length < y.length ? x : y;
  final longer = x.length < y.length ? y : x;
  if (shorter.length >= 6 && longer.contains(shorter) && s < 0.8) s = 0.8;
  return s;
}

String _top(Map<String, int> m) {
  var best = '';
  var bestN = 0;
  m.forEach((k, v) {
    if (v > bestN || (v == bestN && k.length > best.length)) {
      best = k;
      bestN = v;
    }
  });
  return best;
}

String _clock(DateTime d) => d.toIso8601String().substring(11, 19);

String _stamp(DateTime d) =>
    d.toIso8601String().substring(0, 19).replaceFirst('T', ' ');

String _q(String s) => '"${s.replaceAll('"', '""')}"';

// ---------------------------------------------------------------------------
// One photo -> names + country
// ---------------------------------------------------------------------------

class _Found {
  final String text;
  final Rect box;
  final int block;
  _Found(this.text, this.box, this.block);
}

class _Frame {
  final DateTime time;
  final List<String> names;
  final String country; // from the plate (blank if none seen)
  final String hint; // from the legal form in the name
  _Frame(this.time, this.names, this.country, this.hint);
}

_Frame _extractFrame(RecognizedText result, DateTime now) {
  final all = <_Found>[];
  var bi = 0;
  for (final block in result.blocks) {
    for (final line in block.lines) {
      final t = line.text.trim();
      if (t.isNotEmpty) all.add(_Found(t, line.boundingBox, bi));
    }
    bi++;
  }

  // 1) country codes (blue strip letters)
  final strips = <MapEntry<Rect, String>>[];
  for (final f in all) {
    final c = _stripCountry(f.text);
    if (c != null) strips.add(MapEntry(f.box, c));
  }

  // 2) plates and their country (the plate number itself is never stored)
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
  if (cands.isEmpty) {
    final c = plates.isNotEmpty ? plates.first.value : '';
    return _Frame(now, [], c, '');
  }

  // keep only the large lettering, drop small print
  var maxH = 0.0;
  for (final f in cands) {
    if (f.box.height > maxH) maxH = f.box.height;
  }
  final big = cands.where((f) => f.box.height >= maxH * 0.5).toList();
  var primary = big.first;
  for (final f in big) {
    if (f.box.height > primary.box.height) primary = f;
  }

  // names: each line, plus lines of one text block joined together
  final names = <String>[];
  final byBlock = <int, List<String>>{};
  for (final f in big) {
    names.add(f.text);
    byBlock.putIfAbsent(f.block, () => <String>[]).add(f.text);
  }
  for (final lines in byBlock.values) {
    if (lines.length >= 2) {
      final joined = lines.join(' ');
      if (joined.length <= 40) names.add(joined);
    }
  }

  // country: the plate closest to the biggest lettering
  var country = '';
  var bestD = double.infinity;
  for (final p in plates) {
    final d = (p.key.center - primary.box.center).distance;
    if (d < bestD) {
      bestD = d;
      country = p.value;
    }
  }

  var hint = '';
  for (final n in names) {
    final h = _legalHint(n);
    if (h.isNotEmpty) {
      hint = h;
      break;
    }
  }
  return _Frame(now, names, country, hint);
}

// ---------------------------------------------------------------------------
// One truck = everything read about it over several photos
// ---------------------------------------------------------------------------

class Truck {
  final int id;
  final DateTime first;
  DateTime last;
  int frames = 0;
  final Map<String, int> votes = {}; // normalised name -> times seen
  final Map<String, Map<String, int>> spell = {}; // name -> spellings seen
  final Map<String, int> countries = {};
  final Map<String, int> hints = {};

  Truck(this.id, this.first) : last = first;

  void addName(String raw) {
    final k = _alnum(raw);
    if (k.isEmpty) return;
    String key = k;
    for (final e in votes.keys) {
      if (_levRatio(e, k) >= 0.75) {
        key = e;
        break;
      }
    }
    votes[key] = (votes[key] ?? 0) + 1;
    final m = spell.putIfAbsent(key, () => <String, int>{});
    m[raw] = (m[raw] ?? 0) + 1;
  }

  void add(_Frame fr) {
    last = fr.time;
    frames++;
    for (final n in fr.names) {
      addName(n);
    }
    if (fr.country.isNotEmpty) {
      countries[fr.country] = (countries[fr.country] ?? 0) + 1;
    }
    if (fr.hint.isNotEmpty) {
      hints[fr.hint] = (hints[fr.hint] ?? 0) + 1;
    }
  }

  String get _mainKey => _top(votes);

  // the most frequently read name, with its most frequently read spelling
  String get company {
    if (votes.isEmpty) return '';
    final m = spell[_mainKey];
    return m == null ? '' : _top(m);
  }

  String get others {
    final main = _mainKey;
    final keys = votes.keys.where((k) => k != main).toList();
    keys.sort((a, b) => votes[b]!.compareTo(votes[a]!));
    return keys.take(4).map((k) => _top(spell[k]!)).join(' | ');
  }

  String get country => _top(countries);
  String get hint => _top(hints);
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
  final List<Truck> _trucks = []; // newest first
  int _nextId = 1;
  Timer? _timer;
  bool _busy = false;
  bool _scanning = false;
  String? _error;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _zoom = 1.0;

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
      final c = CameraController(desc, ResolutionPreset.ultraHigh,
          enableAudio: false);
      await c.initialize();
      await c.setFlashMode(FlashMode.off);
      try {
        await c.setFocusMode(FocusMode.auto);
      } catch (_) {}
      try {
        await c.setExposureMode(ExposureMode.auto);
      } catch (_) {}
      try {
        _minZoom = await c.getMinZoomLevel();
        _maxZoom = await c.getMaxZoomLevel();
        _zoom = 1.5.clamp(_minZoom, _maxZoom).toDouble();
        await c.setZoomLevel(_zoom);
      } catch (_) {}
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
      final frame = _extractFrame(result, DateTime.now());
      try {
        await File(shot.path).delete();
      } catch (_) {}
      if (mounted) setState(() => _ingest(frame));
    } catch (_) {
      // ignore single-frame failures
    } finally {
      _busy = false;
    }
  }

  // Decide which truck a photo belongs to (or start a new one).
  void _ingest(_Frame fr) {
    if (fr.names.isEmpty && fr.country.isEmpty) return;
    Truck? target;
    if (fr.names.isEmpty) {
      // plate only: attach to the truck seen a moment ago
      target = _latest(fr.time, 2500);
      if (target == null) return;
    } else {
      target = _bestMatch(fr.names, fr.time);
      if (target == null) {
        target = Truck(_nextId++, fr.time);
        _trucks.insert(0, target);
      }
    }
    target.add(fr);
  }

  Truck? _latest(DateTime now, int ms) {
    Truck? best;
    for (final t in _trucks) {
      if (now.difference(t.last).inMilliseconds > ms) continue;
      if (best == null || t.last.isAfter(best.last)) best = t;
    }
    return best;
  }

  Truck? _bestMatch(List<String> names, DateTime now) {
    Truck? best;
    double bestScore = 0;
    for (final t in _trucks) {
      if (now.difference(t.last).inSeconds > 6) continue;
      for (final n in names) {
        for (final k in t.votes.keys) {
          final s = _sim(n, k);
          if (s > bestScore) {
            bestScore = s;
            best = t;
          }
        }
      }
    }
    return bestScore >= 0.6 ? best : null;
  }

  Future<void> _export() async {
    if (_trucks.isEmpty) return;
    // Semicolon separator: opens correctly in Excel with HU/RO regional settings.
    final sb = StringBuffer(
        'truck_no;first_seen;last_seen;company;plate_country;legal_form_hint;other_text;photos\n');
    final list = [..._trucks]..sort((a, b) => a.id.compareTo(b.id));
    for (final t in list) {
      sb.writeln('${t.id};${_stamp(t.first)};${_stamp(t.last)};'
          '${_q(t.company)};${t.country};${t.hint};${_q(t.others)};${t.frames}');
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
      appBar: AppBar(title: Text('Trucks (${_trucks.length})')),
      body: Column(
        children: [
          Expanded(flex: 3, child: preview),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                FilledButton.icon(
                  onPressed: c == null ? null : _toggle,
                  icon: Icon(_scanning ? Icons.stop : Icons.play_arrow),
                  label: Text(_scanning ? 'Stop' : 'Start'),
                ),
                OutlinedButton.icon(
                  onPressed: _trucks.isEmpty ? null : _export,
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Export CSV'),
                ),
                IconButton(
                  onPressed: _trucks.isEmpty
                      ? null
                      : () => setState(() {
                            _trucks.clear();
                            _nextId = 1;
                          }),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
          if (c != null && _maxZoom > _minZoom)
            Row(
              children: [
                const Padding(
                  padding: EdgeInsets.only(left: 16),
                  child: Icon(Icons.zoom_in),
                ),
                Expanded(
                  child: Slider(
                    value: _zoom.clamp(_minZoom, _maxZoom).toDouble(),
                    min: _minZoom,
                    max: _maxZoom,
                    onChanged: (v) {
                      setState(() => _zoom = v);
                      c.setZoomLevel(v);
                    },
                  ),
                ),
              ],
            ),
          Expanded(
            flex: 2,
            child: ListView.builder(
              itemCount: _trucks.length,
              itemBuilder: (_, i) {
                final t = _trucks[i];
                final sub = <String>[
                  if (t.country.isNotEmpty) t.country,
                  if (t.country.isEmpty && t.hint.isNotEmpty)
                    '${t.hint} (name hint)',
                  'seen ${t.frames}x',
                  _clock(t.first),
                ].join(' \u00b7 ');
                return ListTile(
                  dense: true,
                  title: Text('${t.id}. ${t.company}'),
                  subtitle: Text(sub),
                  trailing: t.country.isNotEmpty ? const Icon(Icons.flag) : null,
                  onTap: () => Clipboard.setData(ClipboardData(
                      text: t.country.isEmpty
                          ? t.company
                          : '${t.company}, ${t.country}')),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
