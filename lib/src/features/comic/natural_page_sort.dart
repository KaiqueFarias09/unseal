/// Compares comic page names by embedded numeric values, so `page2` sorts before `page10`.
int compareComicPageNames(final String left, final String right) {
  var leftIndex = 0;
  var rightIndex = 0;
  while (leftIndex < left.length && rightIndex < right.length) {
    final leftCodeUnit = left.codeUnitAt(leftIndex);
    final rightCodeUnit = right.codeUnitAt(rightIndex);
    final leftDigit = leftCodeUnit ^ 0x30;
    final rightDigit = rightCodeUnit ^ 0x30;
    if (leftDigit <= 9 && rightDigit <= 9) {
      var leftNumber = 0;
      var rightNumber = 0;
      while (leftIndex < left.length && (left.codeUnitAt(leftIndex) ^ 0x30) <= 9) {
        leftNumber = leftNumber * 10 + (left.codeUnitAt(leftIndex) ^ 0x30);
        leftIndex++;
      }
      while (rightIndex < right.length && (right.codeUnitAt(rightIndex) ^ 0x30) <= 9) {
        rightNumber = rightNumber * 10 + (right.codeUnitAt(rightIndex) ^ 0x30);
        rightIndex++;
      }

      if (leftNumber != rightNumber) return leftNumber.compareTo(rightNumber);

      continue;
    }
    if (leftCodeUnit != rightCodeUnit) return leftCodeUnit.compareTo(rightCodeUnit);

    leftIndex++;
    rightIndex++;
  }

  return (left.length - leftIndex).compareTo(right.length - rightIndex);
}
