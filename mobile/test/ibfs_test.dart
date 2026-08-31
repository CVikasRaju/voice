import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/ml/ibfs.dart';
import 'package:itantra/ml/languages.dart';

void main() {
  group('iBFS-v1 Codec', () {
    group('Round-trip encode/decode', () {
      test('plain text, no GPS', () {
        final packet = IbfPacket(
          type: PacketType.pttVoice,
          priority: Priority.routine,
          language: kHindi,
          sequenceId: 42,
          text: 'नमस्ते दुनिया',
        );

        final bytes = encodeIbfs(packet);
        final decoded = decodeIbfs(bytes);

        expect(decoded.text, equals('नमस्ते दुनिया'));
        expect(decoded.language.wireId, equals(0x0));
        expect(decoded.priority, equals(Priority.routine));
        expect(decoded.type, equals(PacketType.pttVoice));
        expect(decoded.sequenceId, equals(42));
        expect(decoded.latitude, isNull);
        expect(decoded.longitude, isNull);
      });

      test('with GPS coordinates', () {
        final packet = IbfPacket(
          type: PacketType.pttVoice,
          priority: Priority.emergency,
          language: kHindi,
          sequenceId: 100,
          text: 'help me',
          flags: const PayloadFlags(hasGps: true),
          latitude: 28.6139,
          longitude: 77.2090,
        );

        final bytes = encodeIbfs(packet);
        final decoded = decodeIbfs(bytes);

        expect(decoded.text, equals('help me'));
        expect(decoded.priority, equals(Priority.emergency));
        expect(decoded.latitude, closeTo(28.6139, 0.01));
        expect(decoded.longitude, closeTo(77.2090, 0.01));
        expect(decoded.flags.hasGps, isTrue);
      });

      test('with source language flag', () {
        final packet = IbfPacket(
          type: PacketType.pttVoice,
          priority: Priority.routine,
          language: kHindi,
          sequenceId: 200,
          text: 'translation relay',
          flags: const PayloadFlags(hasSourceLang: true),
          sourceLang: kEnglish,
        );

        final bytes = encodeIbfs(packet);
        final decoded = decodeIbfs(bytes);

        expect(decoded.text, equals('translation relay'));
        expect(decoded.flags.hasSourceLang, isTrue);
        expect(decoded.sourceLang?.wireId, equals(0x9)); // English
      });
    });

    group('All 10 languages', () {
      for (final lang in kLanguages) {
        test('round-trip for ${lang.name} (${lang.code})', () {
          final packet = IbfPacket(
            type: PacketType.pttVoice,
            priority: Priority.routine,
            language: lang,
            sequenceId: lang.wireId + 1000,
            text: 'Test message in ${lang.name}',
          );

          final bytes = encodeIbfs(packet);
          final decoded = decodeIbfs(bytes);

          expect(decoded.text, equals('Test message in ${lang.name}'));
          expect(decoded.language.wireId, equals(lang.wireId));
          expect(decoded.language.name, equals(lang.name));
          expect(decoded.sequenceId, equals(lang.wireId + 1000));
        });
      }
    });

    group('CRC validation', () {
      test('valid CRC passes', () {
        final packet = IbfPacket(
          type: PacketType.pttVoice,
          priority: Priority.routine,
          language: kEnglish,
          sequenceId: 1,
          text: 'hello',
        );
        final bytes = encodeIbfs(packet);
        // Decoding should not throw.
        expect(() => decodeIbfs(bytes), returnsNormally);
      });

      test('corrupted CRC is rejected', () {
        final packet = IbfPacket(
          type: PacketType.pttVoice,
          priority: Priority.routine,
          language: kEnglish,
          sequenceId: 1,
          text: 'hello',
        );
        final bytes = encodeIbfs(packet);

        // Corrupt the last byte (part of CRC).
        bytes[bytes.length - 1] ^= 0xFF;

        expect(
          () => decodeIbfs(bytes),
          throwsA(isA<IbfDecodeError>()),
        );
      });

      test('corrupted payload byte is rejected', () {
        final packet = IbfPacket(
          type: PacketType.pttVoice,
          priority: Priority.routine,
          language: kEnglish,
          sequenceId: 1,
          text: 'hello',
        );
        final bytes = encodeIbfs(packet);

        // Corrupt a payload byte.
        bytes[11] ^= 0xFF;

        expect(
          () => decodeIbfs(bytes),
          throwsA(isA<IbfDecodeError>()),
        );
      });
    });

    group('Decode error cases', () {
      test('too short frame', () {
        expect(
          () => decodeIbfs(Uint8List.fromList([0x49, 0x54])),
          throwsA(isA<IbfDecodeError>()),
        );
      });

      test('bad magic bytes', () {
        final bytes = Uint8List(16);
        bytes[0] = 0x00;
        bytes[1] = 0x00;
        expect(
          () => decodeIbfs(bytes),
          throwsA(isA<IbfDecodeError>()),
        );
      });

      test('unknown language wire ID', () {
        final bytes = Uint8List(16);
        bytes[0] = 0x49; // 'I'
        bytes[1] = 0x54; // 'T'
        bytes[2] = 0x11; // version=1, type=1
        bytes[3] = 0x0E; // priority=0, lang=0xE (unknown)
        // Fill rest with zeros, then compute CRC.
        expect(
          () => decodeIbfs(bytes),
          throwsA(isA<IbfDecodeError>()),
        );
      });
    });

    group('Packet types', () {
      test('PTT voice round-trip', () {
        final packet = IbfPacket(
          type: PacketType.pttVoice,
          priority: Priority.routine,
          language: kHindi,
          sequenceId: 1,
          text: 'test',
        );
        final decoded = decodeIbfs(encodeIbfs(packet));
        expect(decoded.type, equals(PacketType.pttVoice));
      });

      test('Silent SOS round-trip', () {
        final packet = IbfPacket(
          type: PacketType.silentSos,
          priority: Priority.emergency,
          language: kHindi,
          sequenceId: 2,
          text: 'sos',
        );
        final decoded = decodeIbfs(encodeIbfs(packet));
        expect(decoded.type, equals(PacketType.silentSos));
        expect(decoded.priority, equals(Priority.emergency));
      });
    });

    group('Frame size', () {
      test('14-byte overhead for empty text', () {
        final packet = IbfPacket(
          type: PacketType.pttVoice,
          priority: Priority.routine,
          language: kHindi,
          sequenceId: 0,
          text: '',
        );
        final bytes = encodeIbfs(packet);
        // 10 header + 1 flags byte + 0 text + 2 CRC = 13
        expect(bytes.length, equals(13));
      });

      test('overhead + text length', () {
        final packet = IbfPacket(
          type: PacketType.pttVoice,
          priority: Priority.routine,
          language: kHindi,
          sequenceId: 0,
          text: 'hello',
        );
        final bytes = encodeIbfs(packet);
        // 10 header + 1 flags + 5 text + 2 CRC = 18
        expect(bytes.length, equals(18));
      });
    });
  });

  group('CRC-16-CCITT', () {
    test('known test vector', () {
      // CRC-16-CCITT of "123456789" is 0x29B1.
      final data = [0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39];
      final crc = crc16Ccitt(data);
      expect(crc, equals(0x29B1));
    });
  });

  group('Distress detection', () {
    test('Hindi distress keywords', () {
      expect(detectDistress('मदद करो', 'hi'), isTrue);
      expect(detectDistress('बचाओ बचाओ', 'hi'), isTrue);
      expect(detectDistress('घायल हो गया', 'hi'), isTrue);
      expect(detectDistress('आग लग गई', 'hi'), isTrue);
      expect(detectDistress('सब ठीक है', 'hi'), isFalse);
    });

    test('English distress keywords', () {
      expect(detectDistress('help me', 'en'), isTrue);
      expect(detectDistress('I am trapped', 'en'), isTrue);
      expect(detectDistress('fire in the building', 'en'), isTrue);
      expect(detectDistress('SOS', 'en'), isTrue);
      expect(detectDistress('everything is fine', 'en'), isFalse);
    });

    test('Tamil distress keywords', () {
      expect(detectDistress('உதவி', 'ta'), isTrue);
      expect(detectDistress('தீ பிடித்துவிட்டது', 'ta'), isTrue);
      expect(detectDistress('எல்லாம் நல்லா இருக்கு', 'ta'), isFalse);
    });

    test('Gujarati distress keywords', () {
      expect(detectDistress('મદદ કરો', 'gu'), isTrue);
      expect(detectDistress('આગ લાગી', 'gu'), isTrue);
      expect(detectDistress('બધું સારું છે', 'gu'), isFalse);
    });

    test('case insensitive matching', () {
      expect(detectDistress('HELP', 'en'), isTrue);
      expect(detectDistress('Trapped', 'en'), isTrue);
    });
  });

  group('PayloadFlags', () {
    test('no flags', () {
      const flags = PayloadFlags();
      expect(flags.toByte(), equals(0x00));
      expect(PayloadFlags.fromByte(0x00).hasGps, isFalse);
      expect(PayloadFlags.fromByte(0x00).hasSourceLang, isFalse);
    });

    test('GPS flag', () {
      const flags = PayloadFlags(hasGps: true);
      expect(flags.toByte(), equals(0x80));
      final decoded = PayloadFlags.fromByte(0x80);
      expect(decoded.hasGps, isTrue);
      expect(decoded.hasSourceLang, isFalse);
    });

    test('source language flag', () {
      const flags = PayloadFlags(hasSourceLang: true);
      expect(flags.toByte(), equals(0x40));
      final decoded = PayloadFlags.fromByte(0x40);
      expect(decoded.hasGps, isFalse);
      expect(decoded.hasSourceLang, isTrue);
    });

    test('both flags', () {
      const flags = PayloadFlags(hasGps: true, hasSourceLang: true);
      expect(flags.toByte(), equals(0xC0));
      final decoded = PayloadFlags.fromByte(0xC0);
      expect(decoded.hasGps, isTrue);
      expect(decoded.hasSourceLang, isTrue);
    });
  });
}
