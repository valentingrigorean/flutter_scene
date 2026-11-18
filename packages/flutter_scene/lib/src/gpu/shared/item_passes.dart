/// The pass mask of a kept item's one pass [pass], from 0 to 63 (bit n:
/// pass n). On the web, where a shift past 31 bits reads 0, the bits from
/// 32 on are made by a product, which holds each one exactly.
int itemPassBit(int pass) {
  assert(pass >= 0 && pass < 64, 'a pass index is from 0 to 63: $pass');
  return pass < 32 ? 1 << pass : (1 << (pass - 32)) * 0x100000000;
}

/// Whether the pass mask [passes] holds [pass], from 0 to 63. On the web a
/// bitwise operation reads the low 32 bits alone, so the high word is read
/// by division.
bool itemPassesHold(int passes, int pass) {
  assert(pass >= 0 && pass < 64, 'a pass index is from 0 to 63: $pass');
  if (pass < 32) return passes & (1 << pass) != 0;
  return _high(passes) & (1 << (pass - 32)) != 0;
}

/// The number of passes the pass mask [passes] holds.
int itemPassCount(int passes) =>
    _bits(passes & 0xFFFFFFFF) + _bits(_high(passes));

int _bits(int word) {
  var count = 0;
  for (var left = word; left != 0; left &= left - 1) {
    count++;
  }
  return count;
}

int _high(int passes) =>
    ((passes - (passes & 0xFFFFFFFF)) ~/ 0x100000000) & 0xFFFFFFFF;
