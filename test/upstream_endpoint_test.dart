import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/models/upstream_endpoint.dart';

void main() {
  group('UpstreamEndpoint.splitInput', () {
    test('a pasted QUIC URL yields its carrier, host and port', () {
      final split = UpstreamEndpoint.splitInput(' quic://node.example:10811 ');
      expect(split?.host, 'node.example');
      expect(split?.port, 10811);
      expect(split?.transport, UpstreamTransport.quic);
    });

    test('a URL without a port leaves the port field alone', () {
      final split = UpstreamEndpoint.splitInput('quic://[2001:db8::1]');
      expect(split?.host, '2001:db8::1');
      expect(split?.port, isNull);
      expect(split?.transport, UpstreamTransport.quic);
      expect(
        UpstreamEndpoint.splitInput('tcp://node.example')?.transport,
        UpstreamTransport.tcp,
      );
    });

    test('host:port keeps the selected carrier', () {
      final named = UpstreamEndpoint.splitInput('node.example:1081');
      expect(named?.host, 'node.example');
      expect(named?.port, 1081);
      expect(named?.transport, isNull);
      final bracketed = UpstreamEndpoint.splitInput('[2001:db8::1]:443');
      expect(bracketed?.host, '2001:db8::1');
      expect(bracketed?.port, 443);
    });

    test('bare hosts, bare IPv6 and malformed input are left as typed', () {
      for (final input in [
        'node.example',
        '2001:db8::1',
        'quic://',
        'quic://bad host:1',
        'http://node.example:80',
        'node.example:99999',
        'node.example:',
      ]) {
        expect(UpstreamEndpoint.splitInput(input), isNull, reason: input);
      }
    });
  });

  test('labels name the carrier only when it is QUIC', () {
    expect(endpointLabel('node.example', 1081), 'node.example:1081');
    expect(
      endpointLabel('quic://node.example', 10811),
      'node.example:10811 · QUIC',
    );
    expect(endpointLabel('quic://[::1]', 10811), '[::1]:10811 · QUIC');
    expect(endpointLabel('bad host', 1), 'bad host:1');
    expect(UpstreamEndpoint.parse('quic://[::1]:10811').address, '[::1]:10811');
  });
}
