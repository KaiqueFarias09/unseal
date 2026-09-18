/// Counts the number of set bits in [value].
int countSetBits(int value) {
  var count = 0;
  while (value > 0) {
    count += value & 1;
    value >>= 1;
  }

  return count;
}
