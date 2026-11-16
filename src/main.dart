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

class Hit {
  final DateTime time;
  final String text;
  final bool company;
  Hit(this.time, this.text, this.company);
}

const _companyTokens = [
  'SRL', 'S.R.L', 'KFT', 'ZRT', 'GMBH', 'LTD', 'LLC', 'SP.Z',
  'TRANS', 'LOGISTIC', 'SPED', 'CARGO', 'EXPRESS',
];

bool _looksLikeCompany(String t) {
  final u = t.toUpperCase();
  return _companyTokens.any(u.contains);
}

bool _keep(String t) {
  if (t.length < 4) return false;
  final letters = RegExp(r'\p{L}', unicode: true).allMatches(t).length;
  return letters / t.length >= 0.5;
}

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
      final now = DateTime.now();
      final fresh = <Hit>[];
      for (final block in result.blocks) {
        for (final line in block.lines) {
          final t = line.text.trim();
          if (_keep(t)) fresh.add(Hit(now, t, _looksLikeCompany(t)));
        }
      }
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
    final sb = StringBuffer('timestamp;text;likely_company\n');
    for (final h in _hits.reversed) {
      final txt = h.text.replaceAll('"', '""');
      sb.writeln('${h.time.toIso8601String()};"$txt";${h.company ? 1 : 0}');
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
                return ListTile(
                  dense: true,
                  title: Text(h.text),
                  subtitle: Text(h.time.toIso8601String().substring(11, 19)),
                  trailing: h.company ? const Icon(Icons.business) : null,
                  onTap: () => Clipboard.setData(ClipboardData(text: h.text)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
