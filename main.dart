import 'dart:io';
import 'package:flutter/foundation.dart';   // kIsWeb
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;   // afegir http: ^1.2.0 al pubspec.yaml

// ─────────────────────────────────────────────────────────────────────────────
// ENTRY POINT
// ─────────────────────────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ⚠️ SUBSTITUEIX AQUESTS VALORS PEL TEU PROJECT URL I ANON KEY
  // Els trobaràs a: Supabase → Settings → API
  await Supabase.initialize(
    url: 'https://mnycdrdtabltpfdowmms.supabase.co',            // 👈 El teu Project URL
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1ueWNkcmR0YWJsdHBmZG93bW1zIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU2NDU2ODksImV4cCI6MjA5MTIyMTY4OX0.GXSZPT2Vhane6gZppm1thgsRw_qBb4DA2NH_fBLTK4w', // 👈 El teu anon key
  );

  runApp(const MyApp());
}

// Accessor global al client de Supabase
final supabase = Supabase.instance.client;

// ─────────────────────────────────────────────────────────────────────────────
// ROOT WIDGET
// ─────────────────────────────────────────────────────────────────────────────
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Reproductor Cloud',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1ABC9C),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const MusicPlayerScreen(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN SCREEN
// ─────────────────────────────────────────────────────────────────────────────
class MusicPlayerScreen extends StatefulWidget {
  const MusicPlayerScreen({super.key});

  @override
  State<MusicPlayerScreen> createState() => _MusicPlayerScreenState();
}

class _MusicPlayerScreenState extends State<MusicPlayerScreen> {
  List<FileObject> _songs = [];
  bool _loading = true;

  final AudioPlayer _player = AudioPlayer();
  FileObject? _currentSong;
  bool _isPlaying = false;

  Map<String, String> _metadata = {};

  @override
  void initState() {
    super.initState();
    _loadSongs();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LÒGICA: CARREGAR LLISTA DES DE SUPABASE STORAGE
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _loadSongs() async {
    try {
      final List<FileObject> files = await supabase
          .storage
          .from('songs')
          .list();
      setState(() {
        _songs = files;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      debugPrint('Error carregant cançons: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LÒGICA: OBTENIR URL I REPRODUIR EN STREAMING
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _playSong(FileObject song) async {
    try {
      final String url = supabase
          .storage
          .from('songs')
          .getPublicUrl(song.name);

      await _player.stop();
      await _player.setUrl(url);
      await _player.play();

      setState(() {
        _currentSong = song;
        _isPlaying = true;
        _metadata = {};
      });

      // Carregar metadades en segon pla
      _loadMetadata(url, song.name);
    } catch (e) {
      debugPrint('Error reproduint cançó: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LÒGICA: METADADES — compatibles amb web i mòbil
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _loadMetadata(String url, String filename) async {
    if (kIsWeb) {
      debugPrint('>>> [Metadades] Plataforma: WEB — ID3 no disponible');
      setState(() {
        _metadata = {
          'title'   : _cleanFilename(filename),
          'artist'  : '',
          'album'   : '',
          'duration': '',
        };
      });
      return;
    }

    debugPrint('>>> [Metadades] Iniciant càrrega per: $filename');

    try {
      // 1. Descarregar el fitxer
      debugPrint('>>> [Metadades] Descarregant des de: $url');
      final response = await http.get(Uri.parse(url));
      debugPrint('>>> [Metadades] HTTP status: ${response.statusCode}');
      debugPrint('>>> [Metadades] Mida del fitxer: ${response.bodyBytes.length} bytes');

      if (response.statusCode != 200) {
        throw Exception('HTTP error: ${response.statusCode}');
      }
      if (response.bodyBytes.isEmpty) {
        throw Exception('El fitxer descarregat és buit');
      }

      // 2. Guardar al disc temporal
      final dir = await getTemporaryDirectory();
      final filePath = '${dir.path}/$filename';
      final file = File(filePath);
      await file.writeAsBytes(response.bodyBytes);
      debugPrint('>>> [Metadades] Fitxer guardat a: $filePath');
      debugPrint('>>> [Metadades] Mida al disc: ${await file.length()} bytes');

      // 3. Llegir metadades
      debugPrint('>>> [Metadades] Llegint etiquetes ID3...');
      final metadata = await readMetadata(file, getImage: false);
      debugPrint('>>> [Metadades] title:    ${metadata.title}');
      debugPrint('>>> [Metadades] artist:   ${metadata.artist}');
      debugPrint('>>> [Metadades] album:    ${metadata.album}');
      debugPrint('>>> [Metadades] duration: ${metadata.duration}');

      setState(() {
        _metadata = {
          'title'   : metadata.title    ?? _cleanFilename(filename),
          'artist'  : metadata.artist   ?? 'Artista desconegut',
          'album'   : metadata.album    ?? 'Àlbum desconegut',
          'duration': _formatDuration(metadata.duration),
        };
      });
      debugPrint('>>> [Metadades] UI actualitzada correctament');

      // 4. Eliminar fitxer temporal
      await file.delete();
      debugPrint('>>> [Metadades] Fitxer temporal eliminat');

    } catch (e, stack) {
      debugPrint('>>> [Metadades] ERROR: $e');
      debugPrint('>>> [Metadades] Stack: $stack');
      setState(() {
        _metadata = {
          'title'   : _cleanFilename(filename),
          'artist'  : '',
          'album'   : '',
          'duration': '',
        };
      });
    }
  }
  // ─────────────────────────────────────────────────────────────────────────
  // UTILITATS
  // ─────────────────────────────────────────────────────────────────────────

  // Elimina l'extensió del nom del fitxer per mostrar-lo més net
  String _cleanFilename(String filename) {
    return filename.contains('.')
        ? filename.substring(0, filename.lastIndexOf('.'))
        : filename;
  }

  String _formatDuration(Duration? d) {
    if (d == null) return '--:--';
    final String min = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final String sec = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$min:$sec';
  }

  // ─────────────────────────────────────────────────────────────────────────
  // CONTROLS DE REPRODUCCIÓ
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _togglePlayPause() async {
    if (_isPlaying) {
      await _player.pause();
    } else {
      await _player.play();
    }
    setState(() => _isPlaying = !_isPlaying);
  }

  void _playNext() {
    if (_currentSong == null || _songs.isEmpty) return;
    final int i = _songs.indexWhere((s) => s.name == _currentSong!.name);
    if (i < _songs.length - 1) _playSong(_songs[i + 1]);
  }

  void _playPrevious() {
    if (_currentSong == null || _songs.isEmpty) return;
    final int i = _songs.indexWhere((s) => s.name == _currentSong!.name);
    if (i > 0) _playSong(_songs[i - 1]);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // UI: BUILD PRINCIPAL
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Reproductor Cloud')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reproductor Cloud'),
        backgroundColor: const Color(0xFF1F3864),
        foregroundColor: Colors.white,
        actions: [
          // Indicador de plataforma (útil durant el desenvolupament)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Icon(
              kIsWeb ? Icons.web : Icons.phone_android,
              color: Colors.white54,
              size: 18,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_currentSong != null) _buildMetadataPanel(),
          Expanded(child: _buildSongList()),
          if (_currentSong != null) _buildPlayerControls(),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // UI: PANELL DE METADADES
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildMetadataPanel() {
    return Container(
      width: double.infinity,
      color: const Color(0xFF1F3864),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _metadata['title'] ?? _cleanFilename(_currentSong!.name),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          if ((_metadata['artist'] ?? '').isNotEmpty)
            Text(
              'Artista: ${_metadata["artist"]}',
              style: const TextStyle(color: Color(0xFFA8C4E0), fontSize: 14),
            ),
          if ((_metadata['album'] ?? '').isNotEmpty)
            Text(
              'Àlbum: ${_metadata["album"]}',
              style: const TextStyle(color: Color(0xFFA8C4E0), fontSize: 14),
            ),
          if ((_metadata['duration'] ?? '').isNotEmpty)
            Text(
              'Durada: ${_metadata["duration"]}',
              style: const TextStyle(color: Color(0xFF1ABC9C), fontSize: 14),
            ),
          // Avís si estem a la web (les metadades ID3 no estan disponibles)
          if (kIsWeb)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                '⚠️ Metadades ID3 no disponibles a la versió web.',
                style: TextStyle(color: Color(0xFFFFC107), fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // UI: LLISTA DE CANÇONS
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildSongList() {
    if (_songs.isEmpty) {
      return const Center(
        child: Text(
          'No hi ha cançons al bucket.\nPuja fitxers MP3 a Supabase Storage.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return ListView.builder(
      itemCount: _songs.length,
      itemBuilder: (context, i) {
        final bool isActive = _currentSong?.name == _songs[i].name;
        return ListTile(
          tileColor: isActive
              ? const Color(0xFF1ABC9C).withOpacity(0.2)
              : null,
          leading: Icon(
            isActive && _isPlaying ? Icons.volume_up : Icons.music_note,
            color: isActive ? const Color(0xFF1ABC9C) : null,
          ),
          title: Text(
            _cleanFilename(_songs[i].name),
            style: TextStyle(
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          onTap: () => _playSong(_songs[i]),
        );
      },
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // UI: CONTROLS DE REPRODUCCIÓ
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildPlayerControls() {
    return Container(
      color: const Color(0xFF2E5C8A),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.skip_previous, color: Colors.white, size: 32),
            onPressed: _playPrevious,
          ),
          IconButton(
            icon: Icon(
              _isPlaying
                  ? Icons.pause_circle_filled
                  : Icons.play_circle_filled,
              color: const Color(0xFF1ABC9C),
              size: 56,
            ),
            onPressed: _togglePlayPause,
          ),
          IconButton(
            icon: const Icon(Icons.skip_next, color: Colors.white, size: 32),
            onPressed: _playNext,
          ),
        ],
      ),
    );
  }
}
