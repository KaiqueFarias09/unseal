/// Converts a base-32 (Kindle digit set `0-9 A-V`) string to an integer.
int parseBase32(final String raw) => int.parse(raw, radix: 32);
