@TestOn('vm')
@Tags(['no_docker'])

import 'package:pubspec/pubspec.dart';
import 'package:swiss_knife/swiss_knife_vm.dart';
import 'package:test/test.dart';
import 'dart:io';

import 'package:path/path.dart' as path;

void main() {
  group('DockerCommander.VERSION', () {
    setUp(() {});

    test('Check Version', () async {
      var projectDirectory = Directory.current;

      print(projectDirectory);

      var pubspecFile = File(path.join(projectDirectory.path, 'pubspec.yaml'));

      print('pubspecFile: $pubspecFile');

      var pubSpec = await PubSpec.loadFile(pubspecFile.path);

      print('PubSpec.name: ${pubSpec.name}');
      print('PubSpec.version: ${pubSpec.version}');

      var srcFile = File(path.join(
          projectDirectory.path, 'lib/src/docker_commander_base.dart'));

      print(srcFile);

      var src = await catFile(srcFile);

      var versionMatch = RegExp(r"VERSION\s*=\s*'(.*?)'").firstMatch(src)!;

      var srcVersion = versionMatch.group(1);

      print('srcVersion: $srcVersion');

      expect(pubSpec.version.toString(), equals(srcVersion),
          reason:
              'DockerCommander.VERSION[$srcVersion] != PubSpec.version[${pubSpec.version}]');
    });
  });
}
