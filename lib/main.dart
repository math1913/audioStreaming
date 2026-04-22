import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const String songsBucket = 'songs';

SupabaseClient get supabase => Supabase.instance.client;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final String? configError = await _loadSupabaseConfig();
  if (configError != null) {
    runApp(ConfigurationErrorApp(message: configError));
    return;
  }

  await Supabase.initialize(
    url: dotenv.env['SUPABASE_URL']!.trim(),
    anonKey: dotenv.env['SUPABASE_ANON_KEY']!.trim(),
  );

  runApp(const MyApp());
}

Future<String?> _loadSupabaseConfig() async {
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    return 'No se ha podido cargar el archivo .env. Crea reproductor_audi/.env a partir de .env.example.';
  }

  final String url = dotenv.env['SUPABASE_URL']?.trim() ?? '';
  final String anonKey = dotenv.env['SUPABASE_ANON_KEY']?.trim() ?? '';

  if (url.isEmpty || anonKey.isEmpty) {
    return 'Faltan SUPABASE_URL y/o SUPABASE_ANON_KEY en el archivo .env.';
  }

  if (!url.startsWith('https://') || !url.contains('.supabase.co')) {
    return 'SUPABASE_URL debe tener el formato https://tu-proyecto.supabase.co.';
  }

  return null;
}

class ConfigurationErrorApp extends StatelessWidget {
  const ConfigurationErrorApp({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: const Text('Reproductor Cloud')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.settings, size: 56),
              const SizedBox(height: 16),
              const Text(
                'Configura Supabase',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              const Text(
                'Ejemplo:\nSUPABASE_URL=https://tu-proyecto.supabase.co\nSUPABASE_ANON_KEY=tu-anon-key',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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

class MusicPlayerScreen extends StatefulWidget {
  const MusicPlayerScreen({super.key});

  @override
  State<MusicPlayerScreen> createState() => _MusicPlayerScreenState();
}

class _MusicPlayerScreenState extends State<MusicPlayerScreen> {
  final AudioPlayer _player = AudioPlayer();
  final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..maxConnectionsPerHost = 3;
  final Random _random = Random();
  final TextEditingController _searchController = TextEditingController();
  final Map<String, Map<String, String>> _metadataCache = {};
  final Map<String, Duration> _durationCache = {};
  final Map<String, Future<void>> _metadataInflight = {};

  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;

  List<FileObject> _songs = [];
  FileObject? _currentSong;
  Map<String, String> _metadata = {};

  bool _loading = true;
  bool _isPlaying = false;
  bool _shuffleEnabled = false;
  bool _repeatEnabled = false;
  bool _handlingCompletion = false;

  int _playRequestId = 0;
  String _searchQuery = '';
  String? _loadError;
  double _volume = 1;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _bindPlayerStreams();
    unawaited(_loadSongs());
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    _playerStateSubscription?.cancel();
    _searchController.dispose();
    _httpClient.close(force: true);
    _player.dispose();
    super.dispose();
  }

  List<FileObject> get _filteredSongs {
    final String query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return _songs;
    }

    return _songs.where((song) {
      final String name = song.name.toLowerCase();
      final String cleanName = _cleanFilename(song.name).toLowerCase();
      return name.contains(query) || cleanName.contains(query);
    }).toList();
  }

  void _bindPlayerStreams() {
    _positionSubscription = _player.positionStream.listen((position) {
      if (!mounted) return;
      setState(() => _position = position);
    });

    _durationSubscription = _player.durationStream.listen((duration) {
      if (!mounted) return;
      setState(() => _duration = duration ?? Duration.zero);
    });

    _playerStateSubscription = _player.playerStateStream.listen((state) async {
      if (!mounted) return;
      setState(() => _isPlaying = state.playing);

      if (state.processingState != ProcessingState.completed ||
          _handlingCompletion) {
        return;
      }

      _handlingCompletion = true;
      try {
        if (_repeatEnabled) {
          await _player.seek(Duration.zero);
          await _player.play();
          return;
        }

        final bool moved = _playNext();
        if (!moved) {
          await _player.pause();
          await _player.seek(Duration.zero);
          if (mounted) {
            setState(() {
              _isPlaying = false;
              _position = Duration.zero;
            });
          }
        }
      } finally {
        _handlingCompletion = false;
      }
    });
  }

  Future<void> _loadSongs() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });

    try {
      final List<FileObject> files = await supabase.storage
          .from(songsBucket)
          .list();

      final List<FileObject> mp3Files =
          files
              .where((file) => file.name.toLowerCase().endsWith('.mp3'))
              .toList()
            ..sort(
              (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
            );

      if (!mounted) return;
      setState(() {
        _songs = mp3Files;
        _loading = false;
      });
      unawaited(_preloadMetadataForSongs(mp3Files));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'No se han podido cargar las canciones: $error';
      });
    }
  }

  int _selectSongForPlayback(FileObject song) {
    final int requestId = ++_playRequestId;
    final Map<String, String> initialMetadata = _withDuration(
      _metadataCache[song.name] ?? _buildFallbackMetadata(song.name),
      _durationCache[song.name],
    );

    setState(() {
      _currentSong = song;
      _isPlaying = false;
      _position = Duration.zero;
      _duration = _durationCache[song.name] ?? Duration.zero;
      _metadata = initialMetadata;
    });
    return requestId;
  }

  void _requestPlaySong(FileObject song) {
    final int requestId = _selectSongForPlayback(song);
    unawaited(_startPlayback(song, requestId));
  }

  Future<void> _startPlayback(FileObject song, int requestId) async {
    try {
      final String url = supabase.storage
          .from(songsBucket)
          .getPublicUrl(song.name);

      await _player.stop();
      if (requestId != _playRequestId) return;

      final Duration? loadedDuration = await _player.setUrl(url);
      if (requestId != _playRequestId) {
        await _player.stop();
        return;
      }

      if (loadedDuration != null) {
        _durationCache[song.name] = loadedDuration;
      }

      await _player.setVolume(_volume);
      if (requestId != _playRequestId) return;

      await _player.play();
      if (requestId != _playRequestId) {
        await _player.pause();
        return;
      }

      if (!mounted) return;
      setState(() {
        _isPlaying = true;
        _duration = loadedDuration ?? Duration.zero;
        _metadata = _withDuration(
          _metadataCache[song.name] ?? _buildFallbackMetadata(song.name),
          loadedDuration,
        );
      });

      unawaited(_ensureMetadataLoaded(song));
    } catch (error) {
      if (!mounted || requestId != _playRequestId) return;
      setState(() {
        _isPlaying = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se ha podido reproducir: $error')),
      );
    }
  }

  Future<void> _preloadMetadataForSongs(List<FileObject> songs) async {
    const int batchSize = 2;
    for (int index = 0; index < songs.length; index += batchSize) {
      final Iterable<FileObject> batch = songs.skip(index).take(batchSize);
      await Future.wait(batch.map(_ensureMetadataLoaded));
    }
  }

  Future<void> _ensureMetadataLoaded(FileObject song) {
    if (_metadataCache.containsKey(song.name)) {
      return Future<void>.value();
    }

    return _metadataInflight.putIfAbsent(song.name, () async {
      File? tempFile;

      try {
        final String url = supabase.storage
            .from(songsBucket)
            .getPublicUrl(song.name);
        final Uri uri = Uri.parse(url);
        final HttpClientRequest request = await _httpClient.getUrl(uri);
        final HttpClientResponse response = await request.close();

        if (response.statusCode != HttpStatus.ok) {
          throw HttpException('HTTP ${response.statusCode}', uri: uri);
        }

        final Directory dir = await getTemporaryDirectory();
        final String safeFilename = song.name.replaceAll(
          RegExp(r'[\\/:*?"<>|]'),
          '_',
        );
        tempFile = File('${dir.path}${Platform.pathSeparator}$safeFilename');
        final IOSink sink = tempFile.openWrite();
        await response.pipe(sink);
        await sink.close();

        final metadata = readMetadata(tempFile, getImage: false);
        final Duration? resolvedDuration =
            metadata.duration ?? _durationCache[song.name];

        if (resolvedDuration != null) {
          _durationCache[song.name] = resolvedDuration;
        }

        _metadataCache[song.name] = {
          'title': _fallbackText(metadata.title, _cleanFilename(song.name)),
          'artist': _fallbackText(metadata.artist, 'Artista desconocido'),
          'album': _fallbackText(metadata.album, 'Album desconocido'),
          'duration': _formatDuration(resolvedDuration),
        };
      } catch (_) {
        _metadataCache[song.name] = _withDuration(
          _metadataCache[song.name] ?? _buildFallbackMetadata(song.name),
          _durationCache[song.name],
        );
      } finally {
        _metadataInflight.remove(song.name);
        if (tempFile != null && await tempFile.exists()) {
          await tempFile.delete();
        }
      }

      if (!mounted || _currentSong?.name != song.name) {
        return;
      }

      final Map<String, String>? cachedMetadata = _metadataCache[song.name];
      if (cachedMetadata == null) {
        return;
      }

      setState(() {
        _metadata = cachedMetadata;
        final Duration? cachedDuration = _durationCache[song.name];
        if (cachedDuration != null && _duration == Duration.zero) {
          _duration = cachedDuration;
        }
      });
    });
  }

  Future<void> _togglePlayPause() async {
    if (_currentSong == null) return;

    if (_isPlaying) {
      await _player.pause();
    } else {
      if (_player.processingState == ProcessingState.completed) {
        await _player.seek(Duration.zero);
      }
      await _player.play();
    }
  }

  bool _playNext() {
    if (_currentSong == null || _songs.isEmpty) {
      return false;
    }

    if (_shuffleEnabled) {
      final FileObject? song = _randomSong();
      if (song == null) return false;
      _requestPlaySong(song);
      return true;
    }

    final int index = _songs.indexWhere(
      (song) => song.name == _currentSong!.name,
    );
    if (index >= 0 && index < _songs.length - 1) {
      _requestPlaySong(_songs[index + 1]);
      return true;
    }

    return false;
  }

  void _playPrevious() {
    if (_currentSong == null || _songs.isEmpty) return;

    final int index = _songs.indexWhere(
      (song) => song.name == _currentSong!.name,
    );
    if (index > 0) {
      _requestPlaySong(_songs[index - 1]);
    }
  }

  FileObject? _randomSong() {
    if (_songs.isEmpty) return null;
    if (_songs.length == 1) return _songs.first;

    final List<FileObject> candidates = _songs
        .where((song) => song.name != _currentSong?.name)
        .toList();
    return candidates[_random.nextInt(candidates.length)];
  }

  Future<void> _seekTo(double milliseconds) async {
    final Duration target = Duration(milliseconds: milliseconds.round());
    await _player.seek(target);
    if (mounted) {
      setState(() => _position = target);
    }
  }

  Future<void> _setVolume(double volume) async {
    await _player.setVolume(volume);
    if (mounted) {
      setState(() => _volume = volume);
    }
  }

  String _cleanFilename(String filename) {
    final String baseName = filename.split('/').last;
    return baseName.contains('.')
        ? baseName.substring(0, baseName.lastIndexOf('.'))
        : baseName;
  }

  String _fallbackText(String? value, String fallback) {
    final String text = value?.trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  Map<String, String> _buildFallbackMetadata(String filename) {
    return {
      'title': _cleanFilename(filename),
      'artist': 'Artista desconocido',
      'album': 'Album desconocido',
      'duration': '--:--',
    };
  }

  Map<String, String> _withDuration(
    Map<String, String> metadata,
    Duration? duration,
  ) {
    final Map<String, String> enrichedMetadata = Map<String, String>.from(
      metadata,
    );
    enrichedMetadata['duration'] = _formatDuration(duration);
    return enrichedMetadata;
  }

  String _formatDuration(Duration? duration) {
    if (duration == null || duration <= Duration.zero) {
      return '--:--';
    }

    final String minutes = duration.inMinutes.toString().padLeft(2, '0');
    final String seconds = duration.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reproductor Cloud'),
        backgroundColor: const Color(0xFF1F3864),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Recargar',
            onPressed: _loading ? null : () => unawaited(_loadSongs()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_currentSong != null) _buildMetadataPanel(),
          _buildSearchField(),
          Expanded(child: _buildSongList()),
          if (_currentSong != null) _buildPlayerControls(),
        ],
      ),
    );
  }

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
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          _metadataLine('Artista', _metadata['artist']),
          _metadataLine('Album', _metadata['album']),
          _metadataLine('Durada', _metadata['duration']),
        ],
      ),
    );
  }

  Widget _metadataLine(String label, String? value) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        '$label: ${value == null || value.isEmpty ? '--' : value}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Color(0xFFA8C4E0), fontSize: 14),
      ),
    );
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: TextField(
        controller: _searchController,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          labelText: 'Buscar cancion',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchQuery.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Limpiar busqueda',
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                  icon: const Icon(Icons.clear),
                ),
          border: const OutlineInputBorder(),
        ),
        onChanged: (value) => setState(() => _searchQuery = value),
      ),
    );
  }

  Widget _buildSongList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _loadError!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.redAccent),
          ),
        ),
      );
    }

    if (_songs.isEmpty) {
      return const Center(
        child: Text(
          'No hay canciones MP3 en el bucket songs.',
          textAlign: TextAlign.center,
        ),
      );
    }

    final List<FileObject> visibleSongs = _filteredSongs;
    if (visibleSongs.isEmpty) {
      return const Center(
        child: Text(
          'No hay canciones que coincidan con la busqueda.',
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView.builder(
      itemCount: visibleSongs.length,
      itemBuilder: (context, index) {
        final FileObject song = visibleSongs[index];
        final bool isActive = _currentSong?.name == song.name;

        return ListTile(
          tileColor: isActive
              ? const Color(0xFF1ABC9C).withValues(alpha: 0.18)
              : null,
          leading: _buildSongLeadingIcon(isActive),
          title: Text(
            _cleanFilename(song.name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          subtitle: Text(
            song.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _requestPlaySong(song),
        );
      },
    );
  }

  Widget _buildPlayerControls() {
    return Container(
      color: const Color(0xFF2E5C8A),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildProgressControls(),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: 'Shuffle',
                  color: _shuffleEnabled
                      ? const Color(0xFF1ABC9C)
                      : Colors.white70,
                  onPressed: () {
                    setState(() => _shuffleEnabled = !_shuffleEnabled);
                  },
                  icon: const Icon(Icons.shuffle),
                ),
                IconButton(
                  tooltip: 'Anterior',
                  color: Colors.white,
                  iconSize: 32,
                  onPressed: _playPrevious,
                  icon: const Icon(Icons.skip_previous),
                ),
                IconButton(
                  tooltip: _isPlaying ? 'Pausa' : 'Play',
                  icon: Icon(
                    _isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                    color: const Color(0xFF1ABC9C),
                    size: 56,
                  ),
                  onPressed: () => unawaited(_togglePlayPause()),
                ),
                IconButton(
                  tooltip: 'Siguiente',
                  color: Colors.white,
                  iconSize: 32,
                  onPressed: _playNext,
                  icon: const Icon(Icons.skip_next),
                ),
                IconButton(
                  tooltip: 'Repetir pista',
                  color: _repeatEnabled
                      ? const Color(0xFF1ABC9C)
                      : Colors.white70,
                  onPressed: () {
                    setState(() => _repeatEnabled = !_repeatEnabled);
                  },
                  icon: const Icon(Icons.repeat_one),
                ),
              ],
            ),
            _buildVolumeControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildSongLeadingIcon(bool isActive) {
    return Icon(
      isActive && _isPlaying ? Icons.volume_up : Icons.music_note,
      color: isActive ? const Color(0xFF1ABC9C) : null,
    );
  }

  Widget _buildProgressControls() {
    final Duration duration = _duration;
    final Duration currentPosition =
        duration > Duration.zero && _position > duration ? duration : _position;
    final double maxMilliseconds = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1;
    final double valueMilliseconds = min(
      currentPosition.inMilliseconds.toDouble(),
      maxMilliseconds,
    );

    return Column(
      children: [
        Slider(
          value: valueMilliseconds,
          min: 0,
          max: maxMilliseconds,
          onChanged: duration == Duration.zero
              ? null
              : (value) {
                  setState(() {
                    _position = Duration(milliseconds: value.round());
                  });
                },
          onChangeEnd: duration == Duration.zero
              ? null
              : (value) => unawaited(_seekTo(value)),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_formatDuration(currentPosition)),
            Text(_formatDuration(duration)),
          ],
        ),
      ],
    );
  }

  Widget _buildVolumeControls() {
    return Row(
      children: [
        const Icon(Icons.volume_down, color: Colors.white70),
        Expanded(
          child: Slider(
            value: _volume,
            min: 0,
            max: 1,
            divisions: 10,
            label: '${(_volume * 100).round()}%',
            onChanged: (value) => unawaited(_setVolume(value)),
          ),
        ),
        Text('${(_volume * 100).round()}%'),
      ],
    );
  }
}
