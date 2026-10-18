/*
 * Streaming BLAKE2sp-256 over stdin — the D05 reference harness.
 *
 * Reads the whole input into memory and prints the 32-byte BLAKE2sp
 * digest as lowercase hex. Part of the pinned BLAKE2 reference oracle
 * (CC0 / OpenSSL / Apache-2.0 — see ref/ sources and
 * THIRD_PARTY_NOTICES.md); a development tool only.
 */
#include <stdio.h>
#include <stdlib.h>
#include "blake2.h"

int main(void) {
  size_t cap = 1u << 20;
  size_t len = 0;
  uint8_t *buf = malloc(cap);
  if (buf == NULL) return 2;
  for (;;) {
    const size_t n = fread(buf + len, 1, cap - len, stdin);
    len += n;
    if (n == 0) break;
    if (len == cap) {
      cap <<= 1;
      uint8_t *grown = realloc(buf, cap);
      if (grown == NULL) {
        free(buf);
        return 2;
      }
      buf = grown;
    }
  }
  if (ferror(stdin)) {
    free(buf);
    return 2;
  }
  uint8_t out[32];
  if (blake2sp(out, sizeof(out), buf, len, NULL, 0) != 0) {
    free(buf);
    return 3;
  }
  for (size_t i = 0; i < sizeof(out); ++i) printf("%02x", out[i]);
  putchar('\n');
  free(buf);
  return 0;
}
