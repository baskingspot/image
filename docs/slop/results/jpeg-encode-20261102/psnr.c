#include <stdio.h>
#include <stdlib.h>
#include <math.h>
// psnr a.pnm b.pnm: PSNR over every sample, 8-bit
static unsigned char *rd(const char *p, long *n) { FILE *f = fopen(p, "rb"); char m[3]; int w, h, v; if (fscanf(f, "%2s %d %d %d", m, &w, &h, &v) != 4) exit(1); fgetc(f); *n = (long)w * h * (m[1] == '6' ? 3 : 1); unsigned char *b = malloc(*n); if (fread(b, 1, *n, f) != (size_t)*n) exit(1); fclose(f); return b; }
int main(int c, char **v) { long n, m; unsigned char *a = rd(v[1], &n), *b = rd(v[2], &m); if (n != m) return 1; double s = 0; for (long i = 0; i < n; i++) { double d = (double)a[i] - b[i]; s += d * d; } printf("%.4f\n", 10 * log10(255.0 * 255.0 / (s / n))); return 0; }
