import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:path_provider/path_provider.dart';
import 'firebase_options.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ENTRY POINT
// ─────────────────────────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MyApp());
}

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
  // ── Firebase & llista de cançons ──────────────────────────────────────────
  final FirebaseStorage _storage = FirebaseStorage.instance;
  List<Reference> _songs = [];
  bool _loading = true;

  // ── Reproductor d'àudio ───────────────────────────────────────────────────
  final AudioPlayer _player = AudioPlayer();
  Reference? _currentSong;
  bool _isPlaying = false;

  // ── Metadades de la pista actual ──────────────────────────────────────────
  Map<String, String> _metadata = {};

  // ── Lifecycle ─────────────────────────────────────────────────────────────
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
  // LÒGICA: CARREGAR LLISTA DES DE FIREBASE STORAGE
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _loadSongs() async {
    try {
      // Llista tots els fitxers de la carpeta "songs/" del bucket
      final ListResult result = await _storage.ref('songs/').listAll();
      setState(() {
        _songs = result.items; // Llista de Reference (un per fitxer)
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      debugPrint('Error carregant cançons: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LÒGICA: REPRODUIR UNA CANÇÓ DES DEL CLOUD
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _playSong(Reference songRef) async {
    try {
      // 1. Obtenir la URL de descàrrega autenticada de Firebase Storage
      final String url = await songRef.getDownloadURL();

      // 2. Aturar la reproducció anterior
      await _player.stop();

      // 3. Carregar la nova URL i reproduir en streaming
      await _player.setUrl(url);
      await _player.play();

      setState(() {
        _currentSong = songRef;
        _isPlaying = true;
        _metadata = {}; // Neteja metadades fins que es carreguin
      });

      // 4. Carregar metadades de forma asíncrona (no bloqueja la reproducció)
      _loadMetadata(url, songRef.name);
    } catch (e) {
      debugPrint('Error reproduint cançó: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LÒGICA: LLEGIR METADADES ID3 DEL FITXER MP3
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _loadMetadata(String url, String filename) async {
    try {
      // Descarregar el fitxer a un directori temporal del dispositiu
      final HttpClient client = HttpClient();
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$filename');
      final sink = file.openWrite();
      await response.pipe(sink);
      await sink.close();

      // Llegir les etiquetes ID3 del fitxer temporal
      final metadata = await readMetadata(file, getImage: false);

      setState(() {
        _metadata = {
          'title'   : metadata.title    ?? filename,
          'artist'  : metadata.artist   ?? 'Artista desconegut',
          'album'   : metadata.album    ?? 'Àlbum desconegut',
          'duration': _formatDuration(metadata.duration),
        };
      });

      // Eliminar el fitxer temporal un cop llegits els metadades
      await file.delete();
    } catch (e) {
      // Si hi ha error, mostrar el nom del fitxer com a títol
      setState(() {
        _metadata = {
          'title'   : filename,
          'artist'  : '',
          'album'   : '',
          'duration': '',
        };
      });
      debugPrint('Error llegint metadades: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LÒGICA: CONTROLS DE REPRODUCCIÓ
  // ─────────────────────────────────────────────────────────────────────────
  void _togglePlayPause() async {
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
  // UTILITATS
  // ─────────────────────────────────────────────────────────────────────────
  String _formatDuration(Duration? d) {
    if (d == null) return '--:--';
    final String min = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final String sec = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$min:$sec';
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
      ),
      body: Column(
        children: [
          // Panell superior: metadades de la cançó actual
          if (_currentSong != null) _buildMetadataPanel(),

          // Llista de cançons disponibles al cloud
          Expanded(
            child: ListView.builder(
              itemCount: _songs.length,
              itemBuilder: (context, i) {
                final bool isActive = _currentSong?.name == _songs[i].name;
                return ListTile(
                  tileColor: isActive
                      ? const Color(0xFF1ABC9C).withOpacity(0.2)
                      : null,
                  leading: Icon(
                    isActive && _isPlaying
                        ? Icons.volume_up
                        : Icons.music_note,
                    color: isActive ? const Color(0xFF1ABC9C) : null,
                  ),
                  title: Text(
                    _songs[i].name,
                    style: TextStyle(
                      fontWeight:
                          isActive ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  onTap: () => _playSong(_songs[i]),
                );
              },
            ),
          ),

          // Controls de reproducció a la part inferior
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
            _metadata['title'] ?? _currentSong!.name,
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
        ],
      ),
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
