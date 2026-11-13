#ifndef WINVM_VIRTIO_GPU_H
#define WINVM_VIRTIO_GPU_H

#include <stdint.h>

#include "fb_display.h"
#include "pcie.h"
#include "virtio.h"

#define HV_GPU_MAX_RESOURCES 16
#define HV_GPU_RETIRED 4

/* One run of guest memory behind a resource; `start` is its offset in the whole backing store. */
typedef struct HvGpuIov {
    uint64_t addr, start;
    uint32_t len;
} HvGpuIov;

typedef struct HvGpuResource {
    uint32_t id, w, h, format;
    uint8_t *pixels;   /* host copy, w * h * 4, filled by TRANSFER_TO_HOST_2D */
    HvGpuIov *iov;
    uint32_t niov;
} HvGpuResource;

typedef struct HvVirtioGpu {
    HvVirtio vio;
    HvFbDisplay *fb;
    uint32_t width, height;   /* the monitor's native size, as told to the guest */
    HvGpuResource res[HV_GPU_MAX_RESOURCES];
    uint32_t scanout_res;     /* resource on screen, 0 = none (boot framebuffer shows) */
    uint8_t *retired[HV_GPU_RETIRED]; /* pixels released lately: freed a few releases later */
    unsigned retired_next;
    uint32_t iov_hint;
    int cursor_on;
    int log;
} HvVirtioGpu;

/* virtio-gpu (2D) on the PCI bus. See virtio_gpu.c for why it is there. */
HvVirtioGpu *hv_virtio_gpu_create(HvMachine *m, HvPcie *bus, HvFbDisplay *fb);
/* The native size of the monitor the guest sees. Before the VM starts, or later: a running
   driver is told the monitor changed. */
void hv_virtio_gpu_set_size(HvVirtioGpu *g, uint32_t w, uint32_t h);

#endif
