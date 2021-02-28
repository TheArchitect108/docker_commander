import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:swiss_knife/swiss_knife.dart';

import 'docker_commander_commands.dart';
import 'docker_commander_host.dart';

final _LOG = Logger('docker_commander/io');

class ContainerInfosLocal extends ContainerInfos {
  final File idFile;
  final List<String> args;

  ContainerInfosLocal(
      String containerName,
      String image,
      this.idFile,
      List<String> ports,
      String containerNetwork,
      String containerHostname,
      this.args)
      : super(containerName, null, image, ports, containerNetwork,
            containerHostname);
}

/// [DockerHost] Implementation for Local Docker machine host.
class DockerHostLocal extends DockerHost {
  String _dockerBinaryPath;

  DockerHostLocal({String dockerBinaryPath})
      : _dockerBinaryPath = isNotEmptyString(dockerBinaryPath, trim: true)
            ? dockerBinaryPath
            : null;

  @override
  Future<bool> initialize() async {
    _dockerBinaryPath ??= await DockerHostLocal.resolveDockerBinaryPath();
    return true;
  }

  /// The Docker binary path.
  String get dockerBinaryPath {
    if (_dockerBinaryPath == null) throw StateError('Null _dockerBinaryPath');
    return _dockerBinaryPath;
  }

  /// Resolves the full path of the Docker binary.
  /// If fails to resolve, returns `docker`.
  static Future<String> resolveDockerBinaryPath() async {
    var processResult = await Process.run('which', <String>['docker'],
        stdoutEncoding: systemEncoding);

    if (processResult.exitCode == 0) {
      var output = processResult.stdout as String;
      output ??= '';
      output = output.trim();

      if (output.isNotEmpty) {
        return output;
      }
    }

    return 'docker';
  }

  @override
  Future<bool> checkDaemon() async {
    var process = Process.run(dockerBinaryPath, <String>['ps']);
    var result = await process;
    return result.exitCode == 0;
  }

  @override
  Future<String> getContainerIDByName(String name) async {
    var cmdArgs = <String>['ps', '-aqf', 'name=$name'];

    _LOG.info(
        'getContainerIDByName[CMD]>\t$dockerBinaryPath ${cmdArgs.join(' ')}');

    var process =
        Process.run(dockerBinaryPath, cmdArgs, stdoutEncoding: systemEncoding);

    var result = await process;
    var id = result.stdout.toString().trim();
    return id;
  }

  ContainerInfosLocal _buildContainerArgs(
    String cmd,
    String imageName,
    String version,
    String containerName,
    List<String> ports,
    String network,
    String hostname,
    Map<String, String> environment,
    Map<String, String> volumes,
    bool cleanContainer,
  ) {
    var image = DockerHost.resolveImage(imageName, version);

    ports = DockerHost.normalizeMappedPorts(ports);

    var cmdArgs = <String>[cmd, '--name', containerName];

    if (ports != null) {
      for (var pair in ports) {
        cmdArgs.add('-p');
        cmdArgs.add(pair);
      }
    }

    String containerNetwork;

    if (isNotEmptyString(network, trim: true)) {
      containerNetwork = network.trim();
      cmdArgs.add('--net');
      cmdArgs.add(containerNetwork);

      var networkHostsIPs = getNetworkRunnersHostnamesAndIPs(network);

      for (var networkContainerName in networkHostsIPs.keys) {
        if (networkContainerName == containerName) continue;

        var hostMaps = networkHostsIPs[networkContainerName];

        for (var host in hostMaps.keys) {
          var ip = hostMaps[host];
          cmdArgs.add('--add-host');
          cmdArgs.add('$host:$ip');
        }
      }
    }

    String containerHostname;

    if (isNotEmptyString(hostname, trim: true)) {
      containerHostname = hostname.trim();
      cmdArgs.add('-h');
      cmdArgs.add(containerHostname);
    }

    volumes?.forEach((k, v) {
      if (isNotEmptyString(k) && isNotEmptyString(k)) {
        cmdArgs.add('-v');
        cmdArgs.add('$k:$v');
      }
    });

    environment?.forEach((k, v) {
      if (isNotEmptyString(k)) {
        cmdArgs.add('-e');
        cmdArgs.add('$k=$v');
      }
    });

    File idFile;
    if (cleanContainer ?? true) {
      cmdArgs.add('--rm');
    }

    idFile = _createTemporaryFile('cidfile');
    cmdArgs.add('--cidfile');
    cmdArgs.add(idFile.path);

    cmdArgs.add(image);

    return ContainerInfosLocal(containerName, image, idFile, ports,
        containerNetwork, containerHostname, cmdArgs);
  }

  @override
  Future<ContainerInfos> createContainer(
    String containerName,
    String imageName, {
    String version,
    List<String> ports,
    String network,
    String hostname,
    Map<String, String> environment,
    Map<String, String> volumes,
    bool cleanContainer = false,
  }) async {
    if (isEmptyString(containerName, trim: true)) {
      return null;
    }

    var containerInfos = _buildContainerArgs(
      'create',
      imageName,
      version,
      containerName,
      ports,
      network,
      hostname,
      environment,
      volumes,
      cleanContainer,
    );

    var cmdArgs = containerInfos.args;

    _LOG.info('create[CMD]>\t$dockerBinaryPath ${cmdArgs.join(' ')}');

    var process = await Process.start(dockerBinaryPath, cmdArgs);
    var exitCode = await process.exitCode;

    if (containerInfos.idFile != null) {
      var id = await _getContainerID(
          containerInfos.containerName, containerInfos.idFile);
      containerInfos.id = id;
    }

    return exitCode == 0 ? containerInfos : null;
  }

  Future<String> _getContainerID(String containerName, File idFile) async {
    String id;
    if (idFile != null) {
      var fileExists = await _waitFile(idFile);
      if (!fileExists) {
        _LOG.warning("idFile doesn't exists: $idFile");
      }
      id = idFile.readAsStringSync().trim();
    } else {
      id = await getContainerIDByName(containerName);
    }
    return id;
  }

  Future<bool> _waitFile(File file, {Duration timeout}) async {
    if (file == null) return false;
    if (file.existsSync() && file.lengthSync() > 1) return true;

    timeout ??= Duration(minutes: 1);
    var init = DateTime.now().millisecondsSinceEpoch;

    var retry = 0;
    while (true) {
      var exists = file.existsSync() && file.lengthSync() > 1;
      if (exists) return true;

      var now = DateTime.now().millisecondsSinceEpoch;
      var elapsed = now - init;
      var remainingTime = timeout.inMilliseconds - elapsed;
      if (remainingTime < 0) return false;

      ++retry;
      var sleep = Math.min(1000, 10 * retry);

      await Future.delayed(Duration(milliseconds: sleep));
    }
  }

  @override
  Future<DockerRunner> run(
    String imageName, {
    String version,
    List<String> imageArgs,
    String containerName,
    List<String> ports,
    String network,
    String hostname,
    Map<String, String> environment,
    Map<String, String> volumes,
    bool cleanContainer = true,
    bool outputAsLines = true,
    int outputLimit,
    OutputReadyFunction stdoutReadyFunction,
    OutputReadyFunction stderrReadyFunction,
    OutputReadyType outputReadyType,
  }) async {
    outputAsLines ??= true;

    outputReadyType ??= DockerHost.resolveOutputReadyType(
        stdoutReadyFunction, stderrReadyFunction);

    stdoutReadyFunction ??= (outputStream, data) => true;
    stderrReadyFunction ??= (outputStream, data) => true;

    var instanceID = DockerProcess.incrementInstanceID();

    if (isEmptyString(containerName, trim: true)) {
      containerName = 'docker_commander-$session-$instanceID';
    }

    var containerInfos = _buildContainerArgs(
      'run',
      imageName,
      version,
      containerName,
      ports,
      network,
      hostname,
      environment,
      volumes,
      cleanContainer,
    );

    var cmdArgs = containerInfos.args;

    if (imageArgs != null) {
      cmdArgs.addAll(imageArgs);
    }

    _LOG.info('run[CMD]>\t$dockerBinaryPath ${cmdArgs.join(' ')}');

    var process = await Process.start(dockerBinaryPath, cmdArgs);

    var containerNetwork = containerInfos.containerNetwork;

    var runner = DockerRunnerLocal(
        this,
        instanceID,
        containerInfos.containerName,
        containerInfos.image,
        process,
        containerInfos.idFile,
        containerInfos.ports,
        containerNetwork,
        containerInfos.containerHostname,
        outputAsLines,
        outputLimit,
        stdoutReadyFunction,
        stderrReadyFunction,
        outputReadyType);

    _runners[instanceID] = runner;
    _processes[instanceID] = runner;

    var ok = await _initializeAndWaitReady(runner, () async {
      if (containerNetwork != null) {
        await _configureContainerNetwork(containerNetwork, runner);
      }
    });

    if (ok) {
      _LOG.info('Runner[$ok]: $runner');
    }

    return runner;
  }

  void _configureContainerNetwork(
      String network, DockerRunnerLocal runner) async {
    if (isEmptyString(network)) return;
    var runnersHostsAndIPs = getNetworkRunnersHostnamesAndIPs(network);

    var oks =
        await DockerCMD.addContainersHostMapping(this, runnersHostsAndIPs);

    var someFail = oks.values.contains('false');

    if (someFail) {
      _LOG.warning(
          'Error configuring containers host mapping> $runnersHostsAndIPs');
    }
  }

  final Map<int, DockerProcess> _processes = {};

  @override
  Future<DockerProcess> exec(
    String containerName,
    String command,
    List<String> args, {
    bool outputAsLines = true,
    int outputLimit,
    OutputReadyFunction stdoutReadyFunction,
    OutputReadyFunction stderrReadyFunction,
    OutputReadyType outputReadyType,
  }) async {
    if (!isContainerRunnerRunning(containerName)) return null;

    var instanceID = DockerProcess.incrementInstanceID();

    outputReadyType ??= DockerHost.resolveOutputReadyType(
        stdoutReadyFunction, stderrReadyFunction);

    stdoutReadyFunction ??= (outputStream, data) => true;
    stderrReadyFunction ??= (outputStream, data) => true;

    var cmdArgs = ['exec', containerName, command, ...?args];
    _LOG.info('docker exec [CMD]>\t$dockerBinaryPath ${cmdArgs.join(' ')}');

    var process = await Process.start(dockerBinaryPath, cmdArgs);

    var dockerProcess = DockerProcessLocal(
        this,
        instanceID,
        containerName,
        process,
        outputAsLines,
        outputLimit,
        stdoutReadyFunction,
        stderrReadyFunction,
        outputReadyType);

    _processes[instanceID] = dockerProcess;

    var ok = await _initializeAndWaitReady(dockerProcess);
    if (ok) {
      _LOG.info('Exec[$ok]: $dockerProcess');
    }

    return dockerProcess;
  }

  Future<bool> _initializeAndWaitReady(DockerProcessLocal dockerProcess,
      [Function() onInitialize]) async {
    var ok = await dockerProcess.initialize();

    if (!ok) {
      _LOG.warning('Initialization issue for $dockerProcess');
      return false;
    }

    if (onInitialize != null) {
      var ret = onInitialize();
      if (ret is Future) {
        await ret;
      }
    }

    var ready = await dockerProcess.waitReady();
    if (!ready) {
      _LOG.warning('Ready issue for $dockerProcess');
      return false;
    }

    return ok;
  }

  @override
  Future<DockerProcess> command(
    String command,
    List<String> args, {
    bool outputAsLines = true,
    int outputLimit,
    OutputReadyFunction stdoutReadyFunction,
    OutputReadyFunction stderrReadyFunction,
    OutputReadyType outputReadyType,
  }) async {
    var instanceID = DockerProcess.incrementInstanceID();

    outputReadyType ??= DockerHost.resolveOutputReadyType(
        stdoutReadyFunction, stderrReadyFunction);

    stdoutReadyFunction ??= (outputStream, data) => true;
    stderrReadyFunction ??= (outputStream, data) => true;

    var cmdArgs = [command, ...?args];
    _LOG.info('docker command [CMD]>\t$dockerBinaryPath ${cmdArgs.join(' ')}');

    var process = await Process.start(dockerBinaryPath, cmdArgs);

    var dockerProcess = DockerProcessLocal(
        this,
        instanceID,
        '',
        process,
        outputAsLines,
        outputLimit,
        stdoutReadyFunction,
        stderrReadyFunction,
        outputReadyType);

    _processes[instanceID] = dockerProcess;

    var ok = await _initializeAndWaitReady(dockerProcess);
    if (ok) {
      _LOG.info('Command[$ok]: $dockerProcess');
    }

    return dockerProcess;
  }

  @override
  Future<bool> stopByName(String name, {Duration timeout}) async {
    if (isEmptyString(name)) return false;

    var time = timeout != null ? timeout.inSeconds : 15;
    if (time < 1) time = 1;

    var process = Process.run(
        dockerBinaryPath, <String>['stop', '--time', '$time', name]);
    var result = await process;
    return result.exitCode == 0;
  }

  final Map<int, DockerRunnerLocal> _runners = {};

  @override
  bool isContainerRunnerRunning(String containerName) =>
      getRunnerByName(containerName)?.isRunning ?? false;

  List<String> getRunnersIPs() => _runners.values.map((e) => e.ip).toList();

  List<String> getNetworkRunnersIPs(String network) => _runners.values
      .where((e) => e.network == network)
      .map((e) => e.ip)
      .toList();

  List<String> getNetworkRunnersHostnames(String network) => _runners.values
      .where((e) => e.network == network)
      .map((e) => e.hostname)
      .toList();

  List<String> getNetworkRunnersNames(String network) => _runners.values
      .where((e) => e.network == network)
      .map((e) => e.containerName)
      .toList();

  Map<String, String> getNetworkRunnersIPsAndHostnames(String network) =>
      Map.fromEntries(_runners.values
          .where((e) => e.network == network)
          .map((e) => MapEntry(e.ip, e.hostname)));

  Map<String, Map<String, String>> getNetworkRunnersHostnamesAndIPs(
          String network) =>
      Map.fromEntries(_runners.values
          .where((r) => r.network == network)
          .map((r) => MapEntry(r.containerName, {r.hostname: r.ip})));

  @override
  List<int> getRunnersInstanceIDs() => _runners.keys.toList();

  @override
  List<String> getRunnersNames() => _runners.values
      .map((r) => r.containerName)
      .where((n) => n != null && n.isNotEmpty)
      .toList();

  @override
  DockerRunnerLocal getRunnerByInstanceID(int instanceID) =>
      _runners[instanceID];

  @override
  DockerRunner getRunnerByName(String name) => _runners.values
      .firstWhere((r) => r.containerName == name, orElse: () => null);

  @override
  DockerProcessLocal getProcessByInstanceID(int instanceID) =>
      _processes[instanceID];

  Directory _temporaryDirectory;

  /// Returns the temporary directory for this instance.
  Directory get temporaryDirectory {
    _temporaryDirectory ??= _createTemporaryDirectory();
    return _temporaryDirectory;
  }

  Directory _createTemporaryDirectory() {
    var systemTemp = Directory.systemTemp;
    return systemTemp.createTempSync('docker_commander_temp-$session');
  }

  void _clearTemporaryDirectory() {
    if (_temporaryDirectory == null) return;

    var files =
        _temporaryDirectory.listSync(recursive: true, followLinks: false);

    for (var file in files) {
      try {
        file.deleteSync(recursive: true);
      }
      // ignore: empty_catches
      catch (ignore) {}
    }
  }

  int _tempFileCount = 0;

  File _createTemporaryFile([String prefix]) {
    if (isEmptyString(prefix, trim: true)) {
      prefix = 'temp-';
    }

    var time = DateTime.now().millisecondsSinceEpoch;
    var id = ++_tempFileCount;

    var file = File('${temporaryDirectory.path}/$prefix-$time-$id.tmp');
    return file;
  }

  /// Closes this instances.
  /// Clears the [temporaryDirectory] directory if necessary.
  @override
  Future<void> close() async {
    _clearTemporaryDirectory();
  }

  @override
  String toString() {
    return 'DockerHostLocal{dockerBinaryPath: $_dockerBinaryPath}';
  }
}

class DockerRunnerLocal extends DockerProcessLocal implements DockerRunner {
  @override
  final String image;

  /// An optional [File] that contains the container ID.
  final File idFile;

  final List<String> _ports;

  final String network;
  final String hostname;

  DockerRunnerLocal(
      DockerHostLocal dockerHost,
      int instanceID,
      String containerName,
      this.image,
      Process process,
      this.idFile,
      this._ports,
      this.network,
      this.hostname,
      bool outputAsLines,
      int outputLimit,
      OutputReadyFunction stdoutReadyFunction,
      OutputReadyFunction stderrReadyFunction,
      OutputReadyType outputReadyType)
      : super(
            dockerHost,
            instanceID,
            containerName,
            process,
            outputAsLines,
            outputLimit,
            stdoutReadyFunction,
            stderrReadyFunction,
            outputReadyType);

  @override
  DockerHostLocal get dockerHost => super.dockerHost as DockerHostLocal;

  String _id;

  @override
  String get id => _id;

  String _ip;

  String get ip => _ip;

  @override
  Future<bool> initialize() async {
    var ok = await super.initialize();

    _id = await dockerHost._getContainerID(containerName, idFile);

    _ip = await DockerCMD.getContainerIP(dockerHost, id);

    return ok;
  }

  @override
  List<String> get ports => List.unmodifiable(_ports ?? []);

  @override
  Future<bool> stop({Duration timeout}) =>
      dockerHost.stopByInstanceID(instanceID, timeout: timeout);

  @override
  String toString() {
    return 'DockerRunnerLocal{id: $id, image: $image, containerName: $containerName}';
  }
}

class DockerProcessLocal extends DockerProcess {
  final Process process;

  final bool outputAsLines;
  final int _outputLimit;

  final OutputReadyFunction _stdoutReadyFunction;
  final OutputReadyFunction _stderrReadyFunction;
  final OutputReadyType _outputReadyType;

  DockerProcessLocal(
      DockerHostLocal dockerHost,
      int instanceID,
      String containerName,
      this.process,
      this.outputAsLines,
      this._outputLimit,
      this._stdoutReadyFunction,
      this._stderrReadyFunction,
      this._outputReadyType)
      : super(dockerHost, instanceID, containerName);

  final Completer<int> _exitCompleter = Completer();

  Future<bool> initialize() async {
    // ignore: unawaited_futures
    process.exitCode.then(_setExitCode);

    var anyOutputReadyCompleter = Completer<bool>();

    setupStdout(_buildOutputStream(
        process.stdout, _stdoutReadyFunction, anyOutputReadyCompleter));
    setupStderr(_buildOutputStream(
        process.stderr, _stderrReadyFunction, anyOutputReadyCompleter));
    setupOutputReadyType(_outputReadyType);

    return true;
  }

  void _setExitCode(int exitCode) {
    if (_exitCode != null) return;
    _exitCode = exitCode;
    _exitCompleter.complete(exitCode);
    this.stdout.getOutputStream().markReady();
    this.stderr.getOutputStream().markReady();
  }

  OutputStream _buildOutputStream(
      Stream<List<int>> stdout,
      OutputReadyFunction outputReadyFunction,
      Completer<bool> anyOutputReadyCompleter) {
    if (outputAsLines) {
      var outputStream = OutputStream<String>(
        systemEncoding,
        true,
        _outputLimit ?? 1000,
        outputReadyFunction,
        anyOutputReadyCompleter,
      );

      stdout
          .transform(systemEncoding.decoder)
          .listen((line) => outputStream.add(line));

      return outputStream;
    } else {
      var outputStream = OutputStream<int>(
        systemEncoding,
        false,
        _outputLimit ?? 1024 * 128,
        outputReadyFunction,
        anyOutputReadyCompleter,
      );

      stdout.listen((b) => outputStream.addAll(b));

      return outputStream;
    }
  }

  @override
  Future<bool> waitReady() async {
    if (isReady) return true;

    switch (outputReadyType) {
      case OutputReadyType.STDOUT:
        return this.stdout.waitReady();
      case OutputReadyType.STDERR:
        return this.stderr.waitReady();
      case OutputReadyType.ANY:
        return this.stdout.waitAnyOutputReady();
      default:
        return this.stdout.waitReady();
    }
  }

  @override
  bool get isReady {
    switch (outputReadyType) {
      case OutputReadyType.STDOUT:
        return this.stdout.isReady;
      case OutputReadyType.STDERR:
        return this.stderr.isReady;
      case OutputReadyType.ANY:
        return this.stdout.isReady || this.stderr.isReady;
      default:
        return this.stdout.isReady;
    }
  }

  @override
  bool get isRunning => _exitCode == null;

  int _exitCode;

  @override
  int get exitCode => _exitCode;

  @override
  Future<int> waitExit({int desiredExitCode}) async {
    var exitCode = await _waitExitImpl();
    if (desiredExitCode != null && exitCode != desiredExitCode) return null;
    return exitCode;
  }

  Future<int> _waitExitImpl() async {
    if (_exitCode != null) return _exitCode;
    var code = await _exitCompleter.future;
    _exitCode ??= code;
    return _exitCode;
  }
}
