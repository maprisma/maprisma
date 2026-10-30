import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// `ssh-keygen -Y verify` for one ed25519 key, in Dart: an OpenSSH signature
/// (PROTOCOL.sshsig) of `message` in `namespace` by the key whose public blob
/// is `key` (the base64 of an allowed_signers line). Ed25519 as RFC 8032.
bool sshSignatureOk(
  List<int> message,
  List<int> signature,
  String namespace,
  String key,
) {
  try {
    final text = ascii.decode(signature);
    final begin = text.indexOf('-----BEGIN SSH SIGNATURE-----');
    final end = text.indexOf('-----END SSH SIGNATURE-----');
    if (begin < 0 || end <= begin) return false;
    final blob = base64.decode(
      text.substring(begin + 29, end).replaceAll(RegExp(r'\s'), ''),
    );
    final reader = _Reader(blob);
    if (ascii.decode(reader.raw(6)) != 'SSHSIG' || reader.uint32() != 1) {
      return false;
    }
    final publicKey = reader.string();
    final signedSpace = reader.string();
    final reserved = reader.string();
    final hashName = ascii.decode(reader.string());
    final inner = _Reader(reader.string());
    if (!reader.done) return false;
    if (base64.encode(publicKey) != key) return false;
    if (utf8.decode(signedSpace) != namespace) return false;
    if (ascii.decode(inner.string()) != 'ssh-ed25519') return false;
    final raw = inner.string();
    if (!inner.done || raw.length != 64) return false;
    final keyReader = _Reader(publicKey);
    if (ascii.decode(keyReader.string()) != 'ssh-ed25519') return false;
    final point = keyReader.string();
    if (!keyReader.done || point.length != 32) return false;
    final List<int> digest;
    if (hashName == 'sha512') {
      digest = sha512.convert(message).bytes;
    } else if (hashName == 'sha256') {
      digest = sha256.convert(message).bytes;
    } else {
      return false;
    }
    final signed = BytesBuilder()
      ..add(ascii.encode('SSHSIG'))
      ..add(_string(utf8.encode(namespace)))
      ..add(_string(reserved))
      ..add(_string(ascii.encode(hashName)))
      ..add(_string(digest));
    return ed25519Verify(point, signed.toBytes(), raw);
  } catch (_) {
    return false;
  }
}

List<int> _string(List<int> data) {
  final length = ByteData(4)..setUint32(0, data.length);
  return [...length.buffer.asUint8List(), ...data];
}

final class _Reader {
  _Reader(this.data);
  final List<int> data;
  var at = 0;
  bool get done => at == data.length;
  List<int> raw(int n) {
    if (at + n > data.length) throw const FormatException('short');
    final out = data.sublist(at, at + n);
    at += n;
    return out;
  }

  int uint32() => ByteData.sublistView(Uint8List.fromList(raw(4))).getUint32(0);
  List<int> string() => raw(uint32());
}

// --- Ed25519 (RFC 8032 section 5.1.7) ------------------------------------------------

final _p = (BigInt.one << 255) - BigInt.from(19);
final _l =
    (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493');
final _d = (BigInt.from(-121665) * BigInt.from(121666).modInverse(_p)) % _p;
final _sqrtM1 = BigInt.two.modPow((_p - BigInt.one) >> 2, _p);

typedef _Point = (BigInt, BigInt, BigInt, BigInt); // extended coordinates

_Point _add(_Point a, _Point b) {
  final (x1, y1, z1, t1) = a;
  final (x2, y2, z2, t2) = b;
  final aa = ((y1 - x1) * (y2 - x2)) % _p;
  final bb = ((y1 + x1) * (y2 + x2)) % _p;
  final cc = (t1 * BigInt.two * _d * t2) % _p;
  final dd = (z1 * BigInt.two * z2) % _p;
  final e = bb - aa, f = dd - cc, g = dd + cc, h = bb + aa;
  return ((e * f) % _p, (g * h) % _p, (f * g) % _p, (e * h) % _p);
}

_Point _multiply(BigInt scalar, _Point point) {
  _Point result = (BigInt.zero, BigInt.one, BigInt.one, BigInt.zero);
  var addend = point;
  while (scalar > BigInt.zero) {
    if (scalar.isOdd) result = _add(result, addend);
    addend = _add(addend, addend);
    scalar >>= 1;
  }
  return result;
}

BigInt _littleEndian(List<int> bytes) {
  var value = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    value = (value << 8) | BigInt.from(bytes[i]);
  }
  return value;
}

List<int> _encode(_Point point) {
  final (x, y, z, _) = point;
  final inverse = z.modInverse(_p);
  final ax = (x * inverse) % _p, ay = (y * inverse) % _p;
  var value = ay | (ax.isOdd ? BigInt.one << 255 : BigInt.zero);
  final out = List<int>.filled(32, 0);
  for (var i = 0; i < 32; i++) {
    out[i] = (value & BigInt.from(0xff)).toInt();
    value >>= 8;
  }
  return out;
}

_Point? _decode(List<int> bytes) {
  final value = _littleEndian(bytes);
  final sign = (value >> 255).toInt();
  final y = value & ((BigInt.one << 255) - BigInt.one);
  if (y >= _p) return null;
  final y2 = (y * y) % _p;
  final x2 = ((y2 - BigInt.one) * (_d * y2 + BigInt.one).modInverse(_p)) % _p;
  var x = x2.modPow((_p + BigInt.from(3)) >> 3, _p);
  if ((x * x - x2) % _p != BigInt.zero) x = (x * _sqrtM1) % _p;
  if ((x * x - x2) % _p != BigInt.zero) return null;
  if (x == BigInt.zero && sign == 1) return null;
  if ((x.isOdd ? 1 : 0) != sign) x = _p - x;
  return (x, y, BigInt.one, (x * y) % _p);
}

final _base = _decode(List<int>.generate(32, (i) => i == 0 ? 0x58 : 0x66))!;

/// Ed25519 verification: [S]B == R + [k]A, with S < L and A a valid point.
bool ed25519Verify(
  List<int> publicKey,
  List<int> message,
  List<int> signature,
) {
  if (publicKey.length != 32 || signature.length != 64) return false;
  final a = _decode(publicKey);
  if (a == null) return false;
  final r = signature.sublist(0, 32);
  final s = _littleEndian(signature.sublist(32));
  if (s >= _l) return false;
  final k =
      _littleEndian(sha512.convert([...r, ...publicKey, ...message]).bytes) %
      _l;
  final (ax, ay, az, at) = _multiply(k, a);
  final check = _add(_multiply(s, _base), (
    (_p - ax) % _p,
    ay,
    az,
    (_p - at) % _p,
  ));
  final encoded = _encode(check);
  for (var i = 0; i < 32; i++) {
    if (encoded[i] != r[i]) return false;
  }
  return true;
}
