import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class MediaService {
  final ImagePicker _picker = ImagePicker();
  final Uuid _uuid = const Uuid();

  Future<String?> pickMemoryPhoto({ImageSource source = ImageSource.gallery}) async {
    final picked = await _picker.pickImage(
      source: source,
      imageQuality: 82,
      maxWidth: 1600,
    );
    if (picked == null) return null;
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(documents.path, 'memory_photos'));
    await directory.create(recursive: true);
    final extension = p.extension(picked.path).isEmpty ? '.jpg' : p.extension(picked.path);
    final destination = p.join(directory.path, '${_uuid.v4()}$extension');
    await File(picked.path).copy(destination);
    return destination;
  }
}
