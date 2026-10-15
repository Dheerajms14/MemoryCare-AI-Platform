import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:uuid/uuid.dart';

import 'translations.dart';

class VoiceService {
  final FlutterTts _tts = FlutterTts();
  final SpeechToText _speech = SpeechToText();
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  final Uuid _uuid = const Uuid();

  bool get isListening => _speech.isListening;

  Future<void> speak(String text, String languageCode, {double rate = 0.42}) async {
    if (text.trim().isEmpty) return;
    await _tts.stop();
    await _tts.setLanguage(languageFor(languageCode).ttsCode);
    await _tts.setSpeechRate(rate.clamp(0.25, 0.60));
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
    await _tts.speak(text);
  }

  Future<bool> listen({
    required String languageCode,
    required void Function(String words, bool finalResult) onWords,
  }) async {
    try {
      final available = await _speech.initialize();
      if (!available) return false;
      await _speech.listen(
        onResult: (result) => onWords(result.recognizedWords, result.finalResult),
        listenOptions: SpeechListenOptions(
          localeId: languageFor(languageCode).speechCode,
          listenFor: const Duration(seconds: 10),
          pauseFor: const Duration(seconds: 3),
          partialResults: true,
          cancelOnError: true,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> stopListening() => _speech.stop();

  Future<String?> startRecording() async {
    if (!await _recorder.hasPermission()) return null;
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(documents.path, 'memory_voice'));
    await directory.create(recursive: true);
    final output = p.join(directory.path, '${_uuid.v4()}.m4a');
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 96000,
        sampleRate: 44100,
      ),
      path: output,
    );
    return output;
  }

  Future<String?> stopRecording() => _recorder.stop();

  Future<void> playRecording(String path) async {
    await _player.stop();
    await _player.play(DeviceFileSource(path));
  }

  Future<void> stopAll() async {
    await _tts.stop();
    await _speech.stop();
    await _player.stop();
  }

  Future<void> dispose() async {
    await stopAll();
    await _recorder.dispose();
    await _player.dispose();
  }
}
