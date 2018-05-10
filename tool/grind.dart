// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_pad.grind;

import 'dart:async';
import 'dart:io';

import 'package:git/git.dart';
import 'package:grinder/grinder.dart';
import 'package:librato/librato.dart';
import 'package:yaml/yaml.dart' as yaml;

final FilePath _buildDir = new FilePath('build');
final FilePath _webDir = new FilePath('web');

Map get _env => Platform.environment;

main(List<String> args) => grind(args);

@Task()
analyze() {
  new PubApp.global('tuneup')..run(['check']);
}

@Task('Analyze the source code with the ddc compiler')
ddc() {
  PubApp ddc = new PubApp.global('dev_compiler');
  ddc.run(['web/scripts/main.dart']);
}

@Task()
testCli() => new TestRunner().testAsync(platformSelector: 'vm');

// This task require a frame buffer to run.
@Task()
testWeb() => new TestRunner().testAsync(platformSelector: 'chrome');

@Task('Run bower')
bower() => run('bower', arguments: ['install', '--force-latest']);

@Task('Build the `web/index.html` entrypoint')
build() {
  // Copy our third party python code into web/.
  new FilePath('third_party/mdetect/mdetect.py').copy(_webDir);

  // Copy the codemirror script into web/scripts.
  new FilePath(_getCodeMirrorScriptPath()).copy(_webDir.join('scripts'));

  // Speed up the build, from 140s to 100s.
  //Pub.build(directories: ['web', 'test']);
  Pub.build(directories: ['web']);

  FilePath mainFile = _buildDir.join('web', 'scripts/main.dart.js');
  log('${mainFile} compiled to ${_printSize(mainFile)}');

  FilePath testFile = _buildDir.join('test', 'web.dart.js');
  if (testFile.exists)
    log('${testFile.path} compiled to ${_printSize(testFile)}');

  FilePath embedFile = _buildDir.join('web', 'scripts/embed.dart.js');
  log('${mainFile} compiled to ${_printSize(embedFile)}');

  // Remove .dart files.
  int count = 0;

  for (FileSystemEntity entity in getDir('build/web/packages')
      .listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    if (!entity.path.endsWith('.dart')) continue;
    count++;
    entity.deleteSync();
  }

  log('Removed $count Dart files');

  // Run vulcanize.
  // Imports vulcanized, not inlined for IE support
  vulcanizeNoExclusion('scripts/imports.html');
  vulcanize('index.html');
  vulcanize('embed-dart.html');
  vulcanize('embed-html.html');
  vulcanize('embed-inline.html');

  return _uploadCompiledStats(mainFile.asFile.lengthSync());
}

/// Return the path for `packages/codemirror/codemirror.js`.
String _getCodeMirrorScriptPath() {
  Map<String, String> packageToUri = {};
  for (String line in new File('.packages').readAsLinesSync()) {
    int index = line.indexOf(':');
    packageToUri[line.substring(0, index)] = line.substring(index + 1);
  }
  String packagePath = Uri.parse(packageToUri['codemirror']).path;
  return '${packagePath}codemirror.js';
}

// Run vulcanize
vulcanize(String filepath) {
  FilePath htmlFile = _buildDir.join('web', filepath);
  log('${htmlFile.path} original: ${_printSize(htmlFile)}');
  ProcessResult result = Process.runSync(
      'vulcanize',
      [
        '--strip-comments',
        '--inline-css',
        '--inline-scripts',
        '--exclude',
        'scripts/embed.dart.js',
        '--exclude',
        'scripts/main.dart.js',
        '--exclude',
        'scripts/codemirror.js',
        '--exclude',
        'scripts/embed_components.html',
        filepath
      ],
      workingDirectory: 'build/web');
  if (result.exitCode != 0) {
    fail('error running vulcanize: ${result.exitCode}\n${result.stderr}');
  }
  htmlFile.asFile.writeAsStringSync(result.stdout);

  log('${htmlFile.path} vulcanize: ${_printSize(htmlFile)}');
}

//Run vulcanize with no exclusions
vulcanizeNoExclusion(String filepath) {
  FilePath htmlFile = _buildDir.join('web', filepath);
  log('${htmlFile.path} original: ${_printSize(htmlFile)}');
  ProcessResult result = Process.runSync('vulcanize',
      ['--strip-comments', '--inline-css', '--inline-scripts', filepath],
      workingDirectory: 'build/web');
  if (result.exitCode != 0) {
    fail('error running vulcanize: ${result.exitCode}\n${result.stderr}');
  }
  htmlFile.asFile.writeAsStringSync(result.stdout);

  log('${htmlFile.path} vulcanize: ${_printSize(htmlFile)}');
}

@Task()
coverage() {
  if (!_env.containsKey('COVERAGE_TOKEN')) {
    log("env var 'COVERAGE_TOKEN' not found");
    return;
  }

  PubApp coveralls = new PubApp.global('dart_coveralls');
  coveralls.run([
    'report',
    '--token',
    _env['COVERAGE_TOKEN'],
    '--retry',
    '2',
    '--exclude-test-files',
    'test/all.dart'
  ]);
}

@DefaultTask()
@Depends(analyze, testCli, coverage, build)
void buildbot() => null;

@Task('Prepare the app for deployment')
@Depends(buildbot)
deploy() {
  // Validate the deploy.

  // `dev` is served from dev.dart-pad.appspot.com
  // `prod` is served from prod.dart-pad.appspot.com and from dartpad.dartlang.org.

  Map app = yaml.loadYaml(new File('web/app.yaml').readAsStringSync());

  List handlers = app['handlers'];
  bool isSecure = false;

  for (Map m in handlers) {
    if (m['url'] == '.*') {
      isSecure = m['secure'] == 'always';
    }
  }

  return GitDir.fromExisting('.').then((GitDir dir) {
    return dir.getCurrentBranch();
  }).then((BranchReference branchRef) {
    final String branch = branchRef.branchName;

    log('branch: ${branch}');

    if (branch == 'prod') {
      if (!isSecure) {
        fail('The prod branch must have `secure: always`.');
      }
    }

    log('\nexecute: `gcloud app deploy build/web/app.yaml --project=dart-pad --no-promote`');
  });
}

@Task()
clean() => defaultClean();

Future _uploadCompiledStats(num mainLength) {
  Map env = Platform.environment;

  if (env.containsKey('LIBRATO_USER') && env.containsKey('TRAVIS_COMMIT')) {
    Librato librato = new Librato.fromEnvVars();
    log('Uploading stats to ${librato.baseUrl}');
    LibratoStat mainSize = new LibratoStat('main.dart.js', mainLength);
    return librato.postStats([mainSize]).then((_) {
      String commit = env['TRAVIS_COMMIT'];
      LibratoLink link = new LibratoLink(
          'github', 'https://github.com/dart-lang/dart-pad/commit/${commit}');
      LibratoAnnotation annotation = new LibratoAnnotation(commit,
          description: 'Commit ${commit}', links: [link]);
      return librato.createAnnotation('build_ui', annotation);
    });
  } else {
    return new Future.value();
  }
}

String _printSize(FilePath file) =>
    '${(file.asFile.lengthSync() + 1023) ~/ 1024}k';
