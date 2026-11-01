// What the Wuffs arm's files share: Wuffs's implementation is compiled
// once, in wuffs-convert.c.
#ifndef WUFFS_ARM_H
#define WUFFS_ARM_H

#include <stddef.h>
#include <stdint.h>

struct wuffs_base__image_decoder__struct;

// Decodes the first frame of `in` with `dec` into `out` as `pixfmt`, with
// no work buffer beyond a static one. Returns the bytes written or 0.
size_t wuffs_arm_decode(struct wuffs_base__image_decoder__struct *dec, const uint8_t *in,
                        size_t len, uint8_t *out, size_t cap, uint32_t pixfmt);

#endif
