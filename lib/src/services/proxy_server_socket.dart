import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// dart:io's request parser parses CONNECT's authority as a URI, which rejects
/// numeric IPv4 and bracketed IPv6 targets. Normalize only the first request
/// line; dart:io still parses all headers and HTTP framing. Plain HTTP replies
/// close their connection, so a later CONNECT cannot bypass this adapter.
class ProxyServerSocket extends Stream<Socket> implements ServerSocket {
  ProxyServerSocket(this._socket);
  final ServerSocket _socket;
  @override
  int get port => _socket.port;
  @override
  InternetAddress get address => _socket.address;
  @override
  Future<ServerSocket> close() => _socket.close();
  @override
  StreamSubscription<Socket> listen(
    void Function(Socket)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _socket
      .map<Socket>(_ProxySocket.new)
      .listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
}

class _ProxySocket extends Stream<Uint8List> implements Socket {
  _ProxySocket(this._socket);
  final Socket _socket;

  Stream<Uint8List> _incoming() async* {
    final iterator = StreamIterator(_socket);
    final pending = <int>[];
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (await iterator.moveNext().timeout(
        deadline.difference(DateTime.now()),
      )) {
        final bytes = iterator.current;
        final newline = bytes.indexOf(10);
        pending.addAll(newline < 0 ? bytes : bytes.take(newline + 1));
        if (pending.length > 8192) {
          throw const FormatException('Request line too long.');
        }
        if (newline < 0) continue;
        final line = ascii.decode(pending);
        if (line.startsWith('CONNECT ')) {
          final match = RegExp(r'^CONNECT ([^ ]+) HTTP/1\.[01]\r\n$')
              .firstMatch(line);
          if (match == null) {
            throw const FormatException('Invalid CONNECT request line.');
          }
          final target = match[1]!;
          final uri = Uri.parse('http://$target');
          if (!uri.hasPort ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty ||
              uri.path.isNotEmpty ||
              uri.hasQuery ||
              uri.hasFragment) {
            throw const FormatException('Invalid CONNECT authority.');
          }
          yield Uint8List.fromList(
            ascii.encode(line.replaceFirst(target, 'http://$target')),
          );
        } else {
          yield Uint8List.fromList(pending);
        }
        if (newline + 1 < bytes.length) {
          yield Uint8List.sublistView(bytes, newline + 1);
        }
        while (await iterator.moveNext()) {
          yield iterator.current;
        }
        return;
      }
    } finally {
      await iterator.cancel();
    }
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _incoming().listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  int get port => _socket.port;
  @override
  int get remotePort => _socket.remotePort;
  @override
  InternetAddress get address => _socket.address;
  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;
  @override
  Encoding get encoding => _socket.encoding;
  @override
  set encoding(Encoding value) {
    _socket.encoding = value;
  }

  @override
  void add(List<int> data) => _socket.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _socket.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _socket.addStream(stream);
  @override
  Future<void> flush() => _socket.flush();
  @override
  Future close() => _socket.close();
  @override
  Future get done => _socket.done;
  @override
  void destroy() => _socket.destroy();
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _socket.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _socket.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
  @override
  void write(Object? object) => _socket.write(object);
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _socket.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _socket.writeln(object);
}
