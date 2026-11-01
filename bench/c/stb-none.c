// stb_image's arm. stb_image reads PNG, JPEG, GIF, BMP, TGA, and Netpbm, so
// those formats' rows go here as their decoders land; it has no QOI.
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#include "stb/stb_image.h"

#include "arm.h"
