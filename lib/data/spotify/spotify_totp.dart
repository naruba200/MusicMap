// TOTP for Spotify's web-player token endpoint (RFC 6238).
//
// The Spotube plugin's nuance file supplies a BASE32 secret + version;
// the token call sends a 6-digit HMAC-SHA1 code over a 30 s window,
// computed against Spotify's server clock. Pure functions, no I/O, so
// they are unit-tested against the RFC 6238 test vectors.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Decodes a BASE32 string (RFC 4648 alphabet A-Z2-7, padding optional,
/// case-insensitive, whitespace tolerated) into bytes.
/// Throws [FormatException] on characters outside the alphabet.
List<int> base32Decode(String input) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final clean =
      input.toUpperCase().replaceAll('=', '').replaceAll(RegExp(r'\s'), '');
  final bytes = <int>[];
  var buffer = 0;
  var bitsLeft = 0;
  for (var i = 0; i < clean.length; i++) {
    final index = alphabet.indexOf(clean[i]);
    if (index < 0) {
      throw FormatException('Invalid base32 character: ${clean[i]}');
    }
    buffer = (buffer << 5) | index;
    bitsLeft += 5;
    if (bitsLeft >= 8) {
      bitsLeft -= 8;
      bytes.add((buffer >> bitsLeft) & 0xFF);
    }
  }
  return bytes;
}

/// RFC 6238 TOTP: [digits] digits, HMAC-SHA1, [periodSeconds] window.
/// [unixSeconds] is seconds since the epoch — pass Spotify's
/// server-time when available, the local clock otherwise.
String generateTotp(
  String base32Secret, {
  required int unixSeconds,
  int digits = 6,
  int periodSeconds = 30,
}) {
  final key = base32Decode(base32Secret);
  final counter = unixSeconds ~/ periodSeconds;
  final counterBytes = Uint8List(8);
  var value = counter;
  for (var i = 7; i >= 0; i--) {
    counterBytes[i] = value & 0xFF;
    value >>= 8;
  }
  final hash = Hmac(sha1, key).convert(counterBytes).bytes;
  final offset = hash[hash.length - 1] & 0x0F;
  final binary = ((hash[offset] & 0x7F) << 24) |
      ((hash[offset + 1] & 0xFF) << 16) |
      ((hash[offset + 2] & 0xFF) << 8) |
      (hash[offset + 3] & 0xFF);
  var mod = 1;
  for (var i = 0; i < digits; i++) {
    mod *= 10;
  }
  return (binary % mod).toString().padLeft(digits, '0');
}
