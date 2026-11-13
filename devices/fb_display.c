#include "fb_display.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* RAMFBCfg written by EDK2 QemuRamFbDxe via fw_cfg DMA to "etc/ramfb" (28 bytes, big-endian):
   struct RAMFBCfg {
       uint64_t addr;
       uint32_t fourcc;
       uint32_t flags;
       uint32_t width;
       uint32_t height;
       uint32_t stride;
   } __attribute__((packed));
*/

static uint32_t be32(const uint8_t *p) {
    uint32_t v;
    memcpy(&v, p, 4);
    return __builtin_bswap32(v);
}

static uint64_t be64(const uint8_t *p) {
    uint64_t v;
    memcpy(&v, p, 8);
    return __builtin_bswap64(v);
}

static void on_ramfb_write(void *opaque, const uint8_t *data, uint32_t len) {
    HvFbDisplay *fb = opaque;
    if (len < 28) return;

    uint64_t addr = be64(data + 0);
    uint32_t fourcc = be32(data + 8);
    uint32_t width = be32(data + 16);
    uint32_t height = be32(data + 20);
    uint32_t stride = be32(data + 24);

    if (width < 64 || width > 8192 || height < 64 || height > 8192) return;
    if (stride == 0) stride = width * 4;
    if (stride < width * 2 || stride > 65536) return;

    uint64_t total_bytes = (uint64_t)stride * (height - 1) + (uint64_t)width * 4;
    void *host_ptr = hv_phys_ptr(fb->m, addr, total_bytes);
    if (!host_ptr) {
        fprintf(stderr, "winvm: ramfb ignored invalid PA 0x%llx (%ux%u stride %u)\n",
                (unsigned long long)addr, width, height, stride);
        return;
    }

    pthread_mutex_lock(&fb->mu);
    fb->fb_pa = addr;
    fb->fb_host = (const uint8_t *)host_ptr;
    fb->width = width;
    fb->height = height;
    fb->stride = stride;
    fb->fourcc = fourcc;
    fb->active = 1;
    pthread_mutex_unlock(&fb->mu);
    hv_fb_metal_request_redraw();

    fprintf(stderr, "winvm: ramfb configured %ux%u stride=%u fourcc=0x%08x at PA 0x%llx\n",
            width, height, stride, fourcc, (unsigned long long)addr);
}

HvFbDisplay *hv_fb_display_create(HvMachine *m, HvFwCfg *fw_cfg) {
    HvFbDisplay *fb = calloc(1, sizeof *fb);
    fb->m = m;
    pthread_mutex_init(&fb->mu, NULL);
    if (fw_cfg) {
        hv_fw_cfg_add_writable_file(fw_cfg, "etc/ramfb", 28, on_ramfb_write, fb);
    }
    return fb;
}

int hv_fb_display_get_frame(HvFbDisplay *fb, const uint8_t **pixels, uint32_t *w, uint32_t *h, uint32_t *stride) {
    if (!fb) return -1;
    pthread_mutex_lock(&fb->mu);
    if (fb->scanout) {
        *pixels = fb->scanout;
        *w = fb->scanout_w;
        *h = fb->scanout_h;
        *stride = fb->scanout_stride;
        pthread_mutex_unlock(&fb->mu);
        return 0;
    }
    if (!fb->active || !fb->fb_host || !fb->width || !fb->height) {
        pthread_mutex_unlock(&fb->mu);
        return -1;
    }
    *pixels = fb->fb_host;
    *w = fb->width;
    *h = fb->height;
    *stride = fb->stride;
    pthread_mutex_unlock(&fb->mu);
    return 0;
}

void hv_fb_display_set_scanout(HvFbDisplay *fb, const uint8_t *pixels, uint32_t w, uint32_t h, uint32_t stride) {
    if (!fb) return;
    pthread_mutex_lock(&fb->mu);
    int was = fb->scanout != NULL;
    fb->scanout = (pixels && w && h) ? pixels : NULL;
    fb->scanout_w = w;
    fb->scanout_h = h;
    fb->scanout_stride = stride;
    if (!fb->scanout) fb->cursor_on = 0; /* the pointer belongs to the adapter's picture */
    fb->cursor_gen++;
    pthread_mutex_unlock(&fb->mu);
    if (was != (pixels != NULL))
        fprintf(stderr, "winvm: display %s\n", pixels ? "taken over by the display adapter's driver" : "back on the boot framebuffer");
    if (pixels) fprintf(stderr, "winvm: adapter scanout %ux%u\n", w, h);
    hv_fb_metal_request_redraw();
}

void hv_fb_display_set_cursor(HvFbDisplay *fb, const uint8_t *bgra, uint32_t hot_x, uint32_t hot_y,
                              int32_t x, int32_t y, int visible) {
    if (!fb) return;
    pthread_mutex_lock(&fb->mu);
    if (bgra) {
        memcpy(fb->cursor, bgra, sizeof fb->cursor);
        fb->cursor_hot_x = hot_x;
        fb->cursor_hot_y = hot_y;
    }
    fb->cursor_x = x;
    fb->cursor_y = y;
    fb->cursor_on = visible;
    fb->cursor_gen++;
    pthread_mutex_unlock(&fb->mu);
    hv_fb_metal_request_redraw();
}

uint64_t hv_fb_display_get_cursor(HvFbDisplay *fb, uint8_t *bgra_out, int *visible, int32_t *x, int32_t *y,
                                  uint32_t *hot_x, uint32_t *hot_y) {
    pthread_mutex_lock(&fb->mu);
    if (bgra_out) memcpy(bgra_out, fb->cursor, sizeof fb->cursor);
    *visible = fb->cursor_on && fb->scanout != NULL;
    *x = fb->cursor_x;
    *y = fb->cursor_y;
    *hot_x = fb->cursor_hot_x;
    *hot_y = fb->cursor_hot_y;
    uint64_t gen = fb->cursor_gen;
    pthread_mutex_unlock(&fb->mu);
    return gen;
}
