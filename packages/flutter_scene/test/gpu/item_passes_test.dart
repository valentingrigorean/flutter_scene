import 'package:flutter_scene/src/gpu/shared/item_passes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a pass bit holds its pass and no other, past 31 bits too', () {
    for (var pass = 0; pass < 64; pass++) {
      final bit = itemPassBit(pass);
      for (var other = 0; other < 64; other++) {
        expect(itemPassesHold(bit, other), other == pass, reason: '$pass');
      }
      expect(itemPassCount(bit), 1, reason: '$pass');
    }
  });

  test('a mask of a low pass and a high pass holds both', () {
    final passes = itemPassBit(5) + itemPassBit(40);
    expect(itemPassesHold(passes, 5), isTrue);
    expect(itemPassesHold(passes, 40), isTrue);
    expect(itemPassesHold(passes, 8), isFalse);
    expect(itemPassesHold(passes, 41), isFalse);
    expect(itemPassCount(passes), 2);
    expect(itemPassCount(itemPassBit(33) + itemPassBit(63)), 2);
    expect(itemPassCount(0xF), 4);
    expect(itemPassCount(0), 0);
  });

  test('a pass bit is the bit a shift makes on 64-bit integers', () {
    for (var pass = 0; pass < 64; pass++) {
      expect(itemPassBit(pass), 1 << pass, reason: '$pass');
    }
  }, testOn: 'vm');
}
