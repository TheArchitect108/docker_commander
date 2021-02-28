import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:mercury_client/mercury_client.dart';
import 'package:swiss_knife/swiss_knife.dart';

import 'docker_commander_host.dart';

final _LOG = Logger('docker_commander/remote');

class DockerHostRemote extends DockerHost {
  final String serverHost;

  final int serverPort;

  final bool secure;

  final String username;

  final String password;

  final String token;

  HttpClient _httpClient;

  DockerHostRemote(
    this.serverHost,
    this.serverPort, {
    bool secure = false,
    this.username,
    this.password,
    this.token,
  }) : secure = secure ?? false {
    _httpClient = HttpClient(baseURL)
      ..autoChangeAuthorizationToBearerToken('X-Access-Token')
      ..authorization = Authorization.fromProvider(_authenticate);
  }

  String get baseURL {
    var scheme = secure ? 'https' : 'http';
    return '$scheme://$serverHost:$serverPort/';
  }

  Future<Credential> _authenticate(
      HttpClient client, HttpError lastError) async {
    var client = HttpClient(baseURL);

    Credential credential;

    if (isNotEmptyString(token)) {
      credential = BearerCredential(token);
    } else if (isNotEmptyString(username)) {
      credential = BasicCredential(username, password);
    }

    var response = await client.getJSON('/auth', authorization: credential);
    if (response == null) return null;

    return BearerCredential.fromJSONToken(response);
  }

  @override
  Future<bool> initialize() async {
    var ok = await _httpClient.getJSON('initialize') as bool;
    return ok;
  }

  @override
  Future<bool> checkDaemon() async {
    var ok = await _httpClient.getJSON('check_daemon') as bool;
    return ok;
  }

  @override
  Future<void> close() async {
    var ok = await _httpClient.getJSON('close') as bool;
    ok ??= false;

    if (!ok) {
      _LOG.severe("Server operation 'close' returned: $ok");
    }
  }

  @override
  Future<String> getContainerIDByName(String name) async {
    if (isEmptyString(name, trim: true)) return null;
    var id = await _httpClient.getJSON('id_by_name', parameters: {'name': name})
        as String;
    return id;
  }

  @override
  Future<ContainerInfos> createContainer(String containerName, String imageName,
      {String version,
      List<String> ports,
      String network,
      String hostname,
      Map<String, String> environment,
      Map<String, String> volumes,
      bool cleanContainer = false}) async {
    cleanContainer ??= true;

    ports = DockerHost.normalizeMappedPorts(ports);

    var response = await _httpClient.getJSON('create', parameters: {
      'image': imageName,
      'version': version,
      'name': containerName,
      'ports': ports?.join(','),
      'network': network,
      'hostname': hostname,
      'environment': encodeQueryString(environment),
      'volumes': encodeQueryString(volumes),
      'cleanContainer': '$cleanContainer',
    }) as Map;

    containerName = response['containerName'] as String;
    var id = response['id'] as String;
    var image = response['image'] as String;
    var portsList = response['ports'] as List;
    network = response['network'] as String;
    hostname = response['hostname'] as String;

    ports = portsList != null ? portsList.cast<String>().toList() : null;

    return ContainerInfos(containerName, id, image, ports, network, hostname);
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
    cleanContainer ??= true;
    outputAsLines ??= true;

    ports = DockerHost.normalizeMappedPorts(ports);

    var imageArgsEncoded = (imageArgs != null && imageArgs.isNotEmpty)
        ? encodeJSON(imageArgs)
        : null;

    var response = await _httpClient.getJSON('run', parameters: {
      'image': imageName,
      'version': version,
      'imageArgs': imageArgsEncoded,
      'name': containerName,
      'ports': ports?.join(','),
      'network': network,
      'hostname': hostname,
      'environment': encodeQueryString(environment),
      'volumes': encodeQueryString(volumes),
      'cleanContainer': '$cleanContainer',
      'outputAsLines': '$outputAsLines',
      'outputLimit': '$outputLimit',
    }) as Map;

    var instanceID = response['instanceID'] as int;
    containerName = response['containerName'] as String;
    var id = response['id'] as String;

    outputReadyType ??= DockerHost.resolveOutputReadyType(
        stdoutReadyFunction, stderrReadyFunction);

    stdoutReadyFunction ??= (outputStream, data) => true;
    stderrReadyFunction ??= (outputStream, data) => true;

    var image = DockerHost.resolveImage(imageName, version);

    var runner = DockerRunnerRemote(
        this,
        instanceID,
        containerName,
        image,
        ports,
        outputLimit,
        outputAsLines,
        stdoutReadyFunction,
        stderrReadyFunction,
        outputReadyType,
        id);

    _runners[instanceID] = runner;

    var ok = await _initializeAndWaitReady(runner);

    if (ok) {
      _LOG.info('Runner[$ok]: $runner');
    }

    return runner;
  }

  Future<bool> _initializeAndWaitReady(DockerProcessRemote dockerProcess,
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

  final Map<int, DockerProcessRemote> _processes = {};

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
    outputAsLines ??= true;

    var argsEncoded =
        (args != null && args.isNotEmpty) ? encodeJSON(args) : null;

    var response = await _httpClient.getJSON('exec', parameters: {
      'cmd': command,
      'args': argsEncoded,
      'name': containerName,
      'outputAsLines': '$outputAsLines',
      'outputLimit': '$outputLimit',
    }) as Map;

    var instanceID = response['instanceID'] as int;
    containerName = response['containerName'] as String;

    outputReadyType ??= DockerHost.resolveOutputReadyType(
        stdoutReadyFunction, stderrReadyFunction);

    stdoutReadyFunction ??= (outputStream, data) => true;
    stderrReadyFunction ??= (outputStream, data) => true;

    var dockerProcess = DockerProcessRemote(
        this,
        instanceID,
        containerName,
        outputLimit,
        outputAsLines,
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
    outputAsLines ??= true;

    var argsEncoded =
        (args != null && args.isNotEmpty) ? encodeJSON(args) : null;

    var response = await _httpClient.getJSON('command', parameters: {
      'cmd': command,
      'args': argsEncoded,
      'outputAsLines': '$outputAsLines',
      'outputLimit': '$outputLimit',
    }) as Map;

    var instanceID = response['instanceID'] as int;

    outputReadyType ??= DockerHost.resolveOutputReadyType(
        stdoutReadyFunction, stderrReadyFunction);

    stdoutReadyFunction ??= (outputStream, data) => true;
    stderrReadyFunction ??= (outputStream, data) => true;

    var dockerProcess = DockerProcessRemote(
        this,
        instanceID,
        '',
        outputLimit,
        outputAsLines,
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

  Future<OutputSync> processGetOutput(
      int instanceID, int realOffset, bool stderr) async {
    var response = await _httpClient.getJSON(stderr ? 'stderr' : 'stdout',
        parameters: {'instanceID': '$instanceID', 'realOffset': '$realOffset'});
    if (response == null) return null;

    var running = parseBool(response['running'], false);

    if (!running) {
      return OutputSync.notRunning();
    }

    var length = parseInt(response['length']);
    var removed = parseInt(response['removed']);
    var entries = response['entries'] as List;

    return OutputSync(length, removed, entries);
  }

  final Map<int, DockerRunnerRemote> _runners = {};

  @override
  bool isContainerRunnerRunning(String containerName) =>
      getRunnerByName(containerName)?.isRunning ?? false;

  @override
  List<int> getRunnersInstanceIDs() => _runners.keys.toList();

  @override
  List<String> getRunnersNames() => _runners.values
      .map((r) => r.containerName)
      .where((n) => n != null && n.isNotEmpty)
      .toList();

  @override
  DockerRunnerRemote getRunnerByInstanceID(int instanceID) =>
      _runners[instanceID];

  @override
  DockerRunner getRunnerByName(String name) => _runners.values
      .firstWhere((r) => r.containerName == name, orElse: () => null);

  @override
  DockerProcess getProcessByInstanceID(int instanceID) =>
      _processes[instanceID];

  @override
  Future<bool> stopByName(String name, {Duration timeout}) async {
    var ok = await _httpClient.getJSON('stop', parameters: {
      'name': '$name',
      if (timeout != null) 'timeout': '${timeout.inSeconds}',
    }) as bool;
    return ok;
  }

  Future<bool> processWaitReady(int instanceID) async {
    var ok = await _httpClient.getJSON('wait_ready',
        parameters: {'instanceID': '$instanceID'}) as bool;
    return ok;
  }

  Future<int> processWaitExit(int instanceID) async {
    var code = await _httpClient
        .getJSON('wait_exit', parameters: {'instanceID': '$instanceID'}) as int;
    return code;
  }

  @override
  String toString() {
    return 'DockerHostRemote{serverHost: $serverHost, serverPort: $serverPort, secure: $secure, username: $username}';
  }
}

class DockerRunnerRemote extends DockerProcessRemote implements DockerRunner {
  @override
  final String id;

  @override
  final String image;

  final List<String> _ports;

  DockerRunnerRemote(
      DockerHostRemote dockerHostRemote,
      int instanceID,
      String containerName,
      this.image,
      this._ports,
      int outputLimit,
      bool outputAsLines,
      OutputReadyFunction stdoutReadyFunction,
      OutputReadyFunction stderrReadyFunction,
      OutputReadyType outputReadyType,
      this.id)
      : super(
            dockerHostRemote,
            instanceID,
            containerName,
            outputLimit,
            outputAsLines,
            stdoutReadyFunction,
            stderrReadyFunction,
            outputReadyType);

  @override
  List<String> get ports => List.unmodifiable(_ports ?? []);

  @override
  Future<bool> stop({Duration timeout}) =>
      dockerHost.stopByInstanceID(instanceID, timeout: timeout);

  @override
  String toString() {
    return 'DockerRunnerRemote{id: $id, image: $image, containerName: $containerName}';
  }
}

class DockerProcessRemote extends DockerProcess {
  final int outputLimit;
  final bool outputAsLines;

  final OutputReadyFunction _stdoutReadyFunction;
  final OutputReadyFunction _stderrReadyFunction;
  final OutputReadyType _outputReadyType;

  DockerProcessRemote(
    DockerHostRemote dockerHostRemote,
    int instanceID,
    String containerName,
    this.outputLimit,
    this.outputAsLines,
    this._stdoutReadyFunction,
    this._stderrReadyFunction,
    this._outputReadyType,
  ) : super(dockerHostRemote, instanceID, containerName);

  Future<bool> initialize() async {
    var anyOutputReadyCompleter = Completer<bool>();

    setupStdout(_buildOutputStream(
        false, _stdoutReadyFunction, anyOutputReadyCompleter));
    setupStderr(_buildOutputStream(
        true, _stderrReadyFunction, anyOutputReadyCompleter));
    setupOutputReadyType(_outputReadyType);

    return true;
  }

  OutputStream _buildOutputStream(
      bool stderr,
      OutputReadyFunction outputReadyFunction,
      Completer<bool> anyOutputReadyCompleter) {
    if (outputAsLines) {
      var outputStream = OutputStream<String>(
        utf8,
        true,
        outputLimit ?? 1000,
        outputReadyFunction,
        anyOutputReadyCompleter,
      );

      OutputClient(dockerHost, this, stderr, outputStream, (entries) {
        for (var e in entries) {
          outputStream.add(e);
        }
      }).start();

      return outputStream;
    } else {
      var outputStream = OutputStream<int>(
        utf8,
        false,
        outputLimit ?? 1024 * 128,
        outputReadyFunction,
        anyOutputReadyCompleter,
      );

      OutputClient(dockerHost, this, stderr, outputStream, (entries) {
        outputStream.addAll(entries.cast());
      }).start();

      return outputStream;
    }
  }

  @override
  DockerHostRemote get dockerHost => super.dockerHost as DockerHostRemote;

  @override
  bool get isRunning => _exitCode == null;

  int _exitCode;

  void _setExitCode(int exitCode) {
    if (_exitCode != null) return;
    _exitCode = exitCode;
    stdout.getOutputStream().markReady();
    stderr.getOutputStream().markReady();
  }

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

    var code = await dockerHost.processWaitExit(instanceID);
    _setExitCode(code);

    return _exitCode;
  }
}

class OutputSync {
  final bool running;

  final int length;

  final int removed;

  final List entries;

  OutputSync(this.length, this.removed, this.entries) : running = true;

  OutputSync.notRunning()
      : running = false,
        length = null,
        removed = null,
        entries = null;
}

class OutputClient {
  final DockerHostRemote hostRemote;

  final DockerProcessRemote process;

  final bool stderr;

  final OutputStream outputStream;

  final void Function(List entries) entryAdder;

  OutputClient(this.hostRemote, this.process, this.stderr, this.outputStream,
      this.entryAdder);

  int get realOffset =>
      outputStream.entriesRemoved + outputStream.entriesLength;

  bool _running = true;

  int _errorCount = 0;

  Future<bool> sync() async {
    OutputSync outputSync;
    try {
      outputSync = await hostRemote.processGetOutput(
          process.instanceID, realOffset, stderr);
      _errorCount = 0;
    } catch (e) {
      if (_errorCount++ >= 3 || !process.isRunning) {
        _running = false;
      }
      if (process.isRunning) {
        _LOG.warning('Error synching output: $process', e);
      }
      return false;
    }

    if (outputSync == null) return false;

    if (!outputSync.running) {
      _running = false;
    }

    var entries = outputSync.entries;

    if (entries != null) {
      entryAdder(entries);
      return entries.isNotEmpty;
    } else {
      return false;
    }
  }

  void _syncLoop() async {
    var noDataCounter = 0;

    while (_running) {
      var withData = await sync();

      if (!withData) {
        ++noDataCounter;
        var sleep = _resolveNoDataSleep(noDataCounter);
        await Future.delayed(Duration(milliseconds: sleep), () {});
      } else {
        noDataCounter = 0;
      }
    }
  }

  int _resolveNoDataSleep(int noDataCounter) {
    if (noDataCounter <= 1) {
      return 50;
    } else if (noDataCounter <= 100) {
      return (noDataCounter - 1) * 100;
    } else {
      return 10000;
    }
  }

  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    _syncLoop();
  }
}
