// 把一个插件源目录打包为 .lpk（zip）。
//
// 用法：
//   dart run tools/pack_plugin.dart <插件目录> [输出目录]
//
// 示例：
//   dart run tools/pack_plugin.dart plugins_examples/telegram_notify
//
// 产物默认输出到 dist/plugins/<id>-<version>.lpk
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tools/pack_plugin.dart <插件目录> [输出目录]');
    exit(2);
  }
  final pluginDir = args[0];
  final outDir = args.length > 1 ? args[1] : 'dist/plugins';

  final manifestFile = File(p.join(pluginDir, 'manifest.json'));
  if (!manifestFile.existsSync()) {
    stderr.writeln('找不到 manifest.json: ${manifestFile.path}');
    exit(1);
  }
  final manifest = jsonDecode(manifestFile.readAsStringSync()) as Map;
  final id = manifest['id'];
  final version = manifest['version'];
  if (id == null || version == null) {
    stderr.writeln('manifest 缺少 id / version');
    exit(1);
  }

  Directory(outDir).createSync(recursive: true);
  final lpkPath = p.join(outDir, '$id-$version.lpk');
  final out = File(lpkPath);
  if (out.existsSync()) out.deleteSync();

  final encoder = ZipFileEncoder();
  encoder.create(lpkPath);
  for (final entity in Directory(pluginDir).listSync()) {
    final base = p.basename(entity.path);
    if (entity is File) {
      encoder.addFile(entity, base);
    } else if (entity is Directory) {
      encoder.addDirectory(entity, includeDirName: true);
    }
  }
  encoder.closeSync();

  stdout.writeln('已生成: $lpkPath');
}
