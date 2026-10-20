import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:proxy_ui/src/updates/native_update_transport.dart';
import 'package:proxy_ui/src/updates/release_manifest.dart';

/// Test-only boundary implementation; production transfer and crypto are Rust.
class TestUpdateTransport implements UpdateTransport {
  @override
  UpdateOperation start(
    Map<String, Object?> request, {
    void Function(Map<String, dynamic>)? onProgress,
  }) => UpdateOperation(_run(request, onProgress), () {});

  Future<Map<String, dynamic>> _run(
    Map<String, Object?> request,
    void Function(Map<String, dynamic>)? onProgress,
  ) async {
    if (request['operation'] == 'verify_signature') {
      final valid = await Ed25519().verify(
        base64Decode(request['body'] as String),
        signature: Signature(
          base64Decode((request['signature'] as String).trim()),
          publicKey: SimplePublicKey(
            base64Decode(request['public_key'] as String),
            type: KeyPairType.ed25519,
          ),
        ),
      );
      if (!valid) throw const UpdateException(UpdateFailure.signature);
      return {};
    }
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(
        Uri.parse(request['url'] as String),
      )).close();
      if (response.statusCode != 200) {
        throw const UpdateException(UpdateFailure.network);
      }
      final body = await response.fold<List<int>>(
        [],
        (bytes, chunk) => bytes..addAll(chunk),
      );
      if (request['operation'] == 'fetch') return {'body': base64Encode(body)};
      if (body.length != request['size'] ||
          sha256.convert(body).toString() != request['sha256']) {
        throw const UpdateException(UpdateFailure.checksum);
      }
      await File(request['target'] as String).writeAsBytes(body);
      onProgress?.call({
        'received': body.length,
        'total': body.length,
        'bytes_per_second': 100,
      });
      return {};
    } finally {
      client.close(force: true);
    }
  }
}
