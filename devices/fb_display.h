#ifndef WINVM_FB_DISPLAY_H
#define WINVM_FB_DISPLAY_H

#include <pthread.h>
#include <stdint.h>

#include "fw_cfg.h"
#include "machine.h"
#include "pcie.h"

/* Linear framebuffer display supporting QEMU `ramfb` (etc/ramfb in fw_cfg, used by
   EDK2 ArmVirtQemu GOP -> winload.efi -> Windows 11 BasicDisplay.sys + DWM)
   as well as optional VBE/bochs scanout. Zero MMIO exits per pixel write! */

#define HV_FB_CURSOR_SIZE 64u

typedef struct HvFbDisplay {
    HvMachine *m;
    pthread_mutex_t mu;

    /* Active scanout geometry (protected by mu) */
    uint64_t fb_pa;
    const uint8_t *fb_host;
    uint32_t width;
    uint32_t height;
    uint32_t stride;
    uint32_t fourcc; /* DRM fourcc, e.g. XR24 / AR24 (32-bit BGRX) */
    int active;

    /* A display adapter with a guest driver (virtio-gpu) shows its own picture in place of the
       boot framebuffer while its scanout is on (protected by mu). */
    const uint8_t *scanout;
    uint32_t scanout_w, scanout_h, scanout_stride;

    /* The adapter's pointer image, drawn over the picture by the presenter (protected by mu). */
    uint8_t cursor[HV_FB_CURSOR_SIZE * HV_FB_CURSOR_SIZE * 4]; /* BGRA, straight alpha */
    int cursor_on;
    int32_t cursor_x, cursor_y;       /* where the image's hot spot is, in picture pixels */
    uint32_t cursor_hot_x, cursor_hot_y;
    uint64_t cursor_gen;              /* bumps on every change of image, place or visibility */

    /* Metal presenter handle (created lazily by fb_metal.m) */
    void *metal;
} HvFbDisplay;

HvFbDisplay *hv_fb_display_create(HvMachine *m, HvFwCfg *fw_cfg);
/* Thread-safe snapshot of current scanout pointer and dimensions; returns 0 if active, -1 if not yet set. */
int hv_fb_display_get_frame(HvFbDisplay *fb, const uint8_t **pixels, uint32_t *w, uint32_t *h, uint32_t *stride);

/* Show `pixels` (BGRX, stride bytes per row) in place of the boot framebuffer, or go back to the
   boot framebuffer with pixels == NULL. The caller keeps the pixels alive while they are shown,
   and for a little while after (the presenter may be part-way through a frame). */
void hv_fb_display_set_scanout(HvFbDisplay *fb, const uint8_t *pixels, uint32_t w, uint32_t h, uint32_t stride);
/* Pointer image (64x64 BGRA, or NULL to keep the current one), hot spot, position, visibility. */
void hv_fb_display_set_cursor(HvFbDisplay *fb, const uint8_t *bgra, uint32_t hot_x, uint32_t hot_y,
                              int32_t x, int32_t y, int visible);
/* Thread-safe copy of the pointer state; returns its generation. */
uint64_t hv_fb_display_get_cursor(HvFbDisplay *fb, uint8_t *bgra_out, int *visible, int32_t *x, int32_t *y,
                                  uint32_t *hot_x, uint32_t *hot_y);
/* Ask the presenter to draw on its next tick even if no pixel changed (fb_metal.m). */
void hv_fb_metal_request_redraw(void);

/* Metal layer presentation & PNG screenshot helpers (implemented in devices/fb_metal.m) */
void hv_fb_metal_set_layer(HvFbDisplay *fb, void *ca_metal_layer);
uint64_t hv_fb_metal_frames(HvFbDisplay *fb);
int hv_fb_save_png(HvFbDisplay *fb, const char *path);
/* Presentation rate (60 or 30) and magnification filter (0 = linear, 1 = nearest). Any thread. */
void hv_fb_metal_set_fps(int fps);
void hv_fb_metal_set_nearest(int on);
/* 1 = stretch the guest's desktop to cover the layer exactly, instead of keeping its shape and
   padding with black. */
void hv_fb_metal_set_fill(int on);
/* When the guest draws a desktop smaller than the framebuffer and scales it in with black bars,
   the rectangle (in framebuffer pixels) the desktop occupies; returns 0 when it fills the frame. */
int hv_fb_metal_content_rect(uint32_t *x, uint32_t *y, uint32_t *w, uint32_t *h);

#endif
