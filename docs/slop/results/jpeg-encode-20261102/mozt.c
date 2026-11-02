#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <jpeglib.h>
// mozt in.pnm quality sub prog opt reps mode [out.jpg]: mozjpeg; mode plain (JCP_FASTEST), trellis (FASTEST + trellis AC and DC), max (its default profile)
static unsigned char *outbuf; static unsigned long outcap = 1 << 28;
int main(int argc, char **argv) {
  FILE *f = fopen(argv[1], "rb");
  int w, h, maxv; char p[3];
  if (fscanf(f, "%2s %d %d %d", p, &w, &h, &maxv) != 4) return 1;
  fgetc(f);
  int gray = p[1] == '5'; int ch = gray ? 1 : 3;
  unsigned char *px = malloc((size_t)w * h * ch);
  if (fread(px, 1, (size_t)w * h * ch, f) != (size_t)w * h * ch) return 1;
  int q = atoi(argv[2]); const char *sub = argv[3]; int prog = atoi(argv[4]), opt = atoi(argv[5]), reps = atoi(argv[6]);
  outbuf = malloc(outcap);
  struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
  unsigned long outlen = 0;
  for (int r = 0; r < reps; r++) {
    struct jpeg_compress_struct c; struct jpeg_error_mgr err;
    c.err = jpeg_std_error(&err); jpeg_create_compress(&c);
    const char *mode = argv[7];
    if (strcmp(mode, "max")) jpeg_c_set_int_param(&c, JINT_COMPRESS_PROFILE, JCP_FASTEST);
    unsigned char *o = outbuf; outlen = outcap;
    jpeg_mem_dest(&c, &o, &outlen);
    c.image_width = w; c.image_height = h; c.input_components = ch; c.in_color_space = gray ? JCS_GRAYSCALE : JCS_RGB;
    jpeg_set_defaults(&c);
    if (!strcmp(mode, "trellis")) { jpeg_c_set_bool_param(&c, JBOOLEAN_TRELLIS_QUANT, TRUE); jpeg_c_set_bool_param(&c, JBOOLEAN_TRELLIS_QUANT_DC, TRUE); }
    jpeg_set_quality(&c, q, TRUE);
    if (!gray) { int hy = 2, vy = 2; if (!strcmp(sub, "444")) hy = vy = 1; else if (!strcmp(sub, "422")) vy = 1; c.comp_info[0].h_samp_factor = hy; c.comp_info[0].v_samp_factor = vy; }
    if (strcmp(mode, "max")) { c.optimize_coding = opt; if (prog) jpeg_simple_progression(&c); }
    jpeg_start_compress(&c, TRUE);
    while (c.next_scanline < c.image_height) { JSAMPROW row = px + (size_t)c.next_scanline * w * ch; jpeg_write_scanlines(&c, &row, 1); }
    jpeg_finish_compress(&c); jpeg_destroy_compress(&c);
  }
  clock_gettime(CLOCK_MONOTONIC, &t1);
  double ns = (t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec);
  if (argc > 8) { FILE *o = fopen(argv[8], "wb"); fwrite(outbuf, 1, outlen, o); fclose(o); }
  printf("%.1f MP/s (%lu bytes)\n", (double)w * h * reps / ns * 1000, outlen);
  return 0;
}
