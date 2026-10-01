/* Indexed Quake pixels to OPENSTEP Interceptor storage (Intel byte order). */
#ifndef Q2_SWIMP_PIXELS_H
#define Q2_SWIMP_PIXELS_H

#include <string.h>

typedef enum {
    Q2_PIXEL_UNSUPPORTED,
    Q2_PIXEL_RGBX,
    Q2_PIXEL_BGRX,
    Q2_PIXEL_RGB555,
    Q2_PIXEL_RGB565
} q2_pixel_layout;

static q2_pixel_layout Q2_PixelLayout(const char *encoding)
{
    if (!encoding)
        return Q2_PIXEL_UNSUPPORTED;
    if (!strcmp(encoding, "RRRRRRRRGGGGGGGGBBBBBBBBAAAAAAAA") ||
        !strcmp(encoding, "RRRRRRRRGGGGGGGGBBBBBBBB--------"))
        return Q2_PIXEL_RGBX;
    if (!strcmp(encoding, "--------RRRRRRRRGGGGGGGGBBBBBBBB"))
        return Q2_PIXEL_BGRX;
    if (!strcmp(encoding, "RRRRRGGGGGBBBBB") ||
        !strcmp(encoding, "-RRRRRGGGGGBBBBB"))
        return Q2_PIXEL_RGB555;
    /* The legacy Interceptor 18-bit color encoding uses RGB565 storage.
     * This is also the packing used by the local Interceptor example. */
    if (!strcmp(encoding, "RRRRRRGGGGGGBBBBBB") ||
        !strcmp(encoding, "RRRRRGGGGGGBBBBB"))
        return Q2_PIXEL_RGB565;
    return Q2_PIXEL_UNSUPPORTED;
}

static int Q2_PixelBytes(q2_pixel_layout layout)
{
    if (layout == Q2_PIXEL_RGB555 || layout == Q2_PIXEL_RGB565)
        return 2;
    if (layout == Q2_PIXEL_RGBX || layout == Q2_PIXEL_BGRX)
        return 4;
    return 0;
}

/* Build a lookup table once per palette/layout change, not once per pixel. */
static void Q2_PixelPalette(q2_pixel_layout layout,
                            const unsigned char *rgba,
                            unsigned char native[256][4])
{
    int i;
    unsigned r, g, b, packed;

    for (i = 0; i < 256; i++) {
        r = rgba[i * 4];
        g = rgba[i * 4 + 1];
        b = rgba[i * 4 + 2];
        native[i][3] = 0;
        if (layout == Q2_PIXEL_RGB555 || layout == Q2_PIXEL_RGB565) {
            if (layout == Q2_PIXEL_RGB555)
                packed = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
            else
                packed = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
            native[i][0] = packed & 255;
            native[i][1] = packed >> 8;
            native[i][2] = 0;
        } else if (layout == Q2_PIXEL_BGRX) {
            native[i][0] = b;
            native[i][1] = g;
            native[i][2] = r;
        } else {
            native[i][0] = r;
            native[i][1] = g;
            native[i][2] = b;
        }
    }
}

/* Source and destination may both have padding; never write row padding. */
static int Q2_PixelBlit(unsigned char *dst, int dst_stride,
                        const unsigned char *src, int src_stride,
                        int width, int height, q2_pixel_layout layout,
                        const unsigned char native[256][4])
{
    int x, y, bytes;
    const unsigned char *color;
    unsigned char *out;

    bytes = Q2_PixelBytes(layout);
    if (!dst || !src || !bytes || width <= 0 || height <= 0 ||
        src_stride < width || dst_stride / bytes < width)
        return 0;
    for (y = 0; y < height; y++) {
        out = dst + y * dst_stride;
        for (x = 0; x < width; x++) {
            color = native[src[y * src_stride + x]];
            out[0] = color[0];
            out[1] = color[1];
            if (bytes == 4) {
                out[2] = color[2];
                out[3] = color[3];
            }
            out += bytes;
        }
    }
    return 1;
}

#endif
