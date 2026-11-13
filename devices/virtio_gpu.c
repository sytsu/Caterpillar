/* virtio-gpu, 2D only: a display adapter Windows has a driver for (viogpudo, from virtio-win).

   Without a driver Windows draws into the firmware's framebuffer with its basic display driver,
   which has no idea what monitor it is on: it reuses whatever desktop size it used last and
   scales it. With this adapter the guest sees a monitor (EDID and all) whose native size is the
   one the host asks for, and uses it. The boot framebuffer (ramfb) stays in charge through
   firmware and early boot, and for guests without the driver; the driver's scanout replaces it
   once it is set, and a device reset hands the picture back. */
#include "virtio_gpu.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CTRLQ 0
#define CURSORQ 1

#define F_EDID (1ull << 1)

enum {
    CMD_GET_DISPLAY_INFO = 0x0100,
    CMD_RESOURCE_CREATE_2D,
    CMD_RESOURCE_UNREF,
    CMD_SET_SCANOUT,
    CMD_RESOURCE_FLUSH,
    CMD_TRANSFER_TO_HOST_2D,
    CMD_RESOURCE_ATTACH_BACKING,
    CMD_RESOURCE_DETACH_BACKING,
    CMD_GET_CAPSET_INFO,
    CMD_GET_CAPSET,
    CMD_GET_EDID,
    CMD_UPDATE_CURSOR = 0x0300,
    CMD_MOVE_CURSOR,
    RESP_OK_NODATA = 0x1100,
    RESP_OK_DISPLAY_INFO,
    RESP_OK_CAPSET_INFO,
    RESP_OK_CAPSET,
    RESP_OK_EDID,
    RESP_ERR_UNSPEC = 0x1200,
    RESP_ERR_OUT_OF_MEMORY,
    RESP_ERR_INVALID_SCANOUT_ID,
    RESP_ERR_INVALID_RESOURCE_ID,
    RESP_ERR_INVALID_CONTEXT_ID,
    RESP_ERR_INVALID_PARAMETER,
};

#define FLAG_FENCE 1u
#define EVENT_DISPLAY 1u
#define HDR 24u

static uint32_t rd32(const uint8_t *p) {
    uint32_t v;
    memcpy(&v, p, 4);
    return v;
}

static uint64_t rd64(const uint8_t *p) {
    uint64_t v;
    memcpy(&v, p, 8);
    return v;
}

static void wr32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }

/* ---- EDID: one monitor whose only detailed timing is the size the host wants ---- */

static void build_edid(uint8_t e[128], uint32_t w, uint32_t h) {
    memset(e, 0, 128);
    static const uint8_t head[8] = {0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00};
    memcpy(e, head, 8);
    e[8] = 0x0e; /* "CTP" */
    e[9] = 0x90;
    /* Product and serial follow the size, so each size is a different monitor to Windows and it
       starts from that monitor's native mode instead of a size remembered for another one. */
    uint16_t product = (uint16_t)(w * 31u + h);
    memcpy(e + 10, &product, 2);
    uint32_t serial = w << 16 | h;
    memcpy(e + 12, &serial, 4);
    e[16] = 1;
    e[17] = 36; /* 2026 */
    e[18] = 1;
    e[19] = 4;
    e[20] = 0xa5; /* digital, 8 bits per colour, DisplayPort */
    uint32_t mm_w = 140, mm_h = (uint32_t)(140ull * h / w);
    e[21] = (uint8_t)(mm_w / 10);
    e[22] = (uint8_t)(mm_h / 10 ? mm_h / 10 : 1);
    e[23] = 0x78; /* gamma 2.2 */
    e[24] = 0x06; /* RGB, sRGB, preferred timing is native */
    static const uint8_t chroma[10] = {0xee, 0x91, 0xa3, 0x54, 0x4c, 0x99, 0x26, 0x0f, 0x50, 0x54};
    memcpy(e + 25, chroma, 10);
    for (int i = 38; i < 54; i++) e[i] = 0x01; /* no standard timings */

    uint32_t hblank = 160, hfront = 48, hsync = 32, vblank = 35, vfront = 3, vsync = 5;
    uint32_t clock = (uint32_t)(((uint64_t)(w + hblank) * (h + vblank) * 60 + 5000) / 10000);
    uint8_t *d = e + 54;
    d[0] = (uint8_t)clock;
    d[1] = (uint8_t)(clock >> 8);
    d[2] = (uint8_t)w;
    d[3] = (uint8_t)hblank;
    d[4] = (uint8_t)((w >> 8) << 4 | hblank >> 8);
    d[5] = (uint8_t)h;
    d[6] = (uint8_t)vblank;
    d[7] = (uint8_t)((h >> 8) << 4 | vblank >> 8);
    d[8] = (uint8_t)hfront;
    d[9] = (uint8_t)hsync;
    d[10] = (uint8_t)(vfront << 4 | vsync);
    d[11] = 0;
    d[12] = (uint8_t)mm_w;
    d[13] = (uint8_t)mm_h;
    d[14] = (uint8_t)((mm_w >> 8) << 4 | mm_h >> 8);
    d[17] = 0x1e;

    static const uint8_t name[18] = {0, 0, 0, 0xfc, 0, 'C', 'a', 't', 'e', 'r', 'p', 'i', 'l', 'l', 'a', 'r', '\n', ' '};
    memcpy(e + 72, name, 18);
    uint8_t range[18] = {0, 0, 0, 0xfd, 0, 50, 75, 30, 160, (uint8_t)(clock / 1000 + 1), 0, 0x0a, ' ', ' ', ' ', ' ', ' ', ' '};
    memcpy(e + 90, range, 18);
    e[111] = 0x10; /* unused descriptor */

    uint8_t sum = 0;
    for (int i = 0; i < 127; i++) sum = (uint8_t)(sum + e[i]);
    e[127] = (uint8_t)(0x100 - sum);
}

/* ---- resources ---- */

static HvGpuResource *find(HvVirtioGpu *g, uint32_t id) {
    if (!id) return NULL;
    for (int i = 0; i < HV_GPU_MAX_RESOURCES; i++)
        if (g->res[i].id == id) return &g->res[i];
    return NULL;
}

static void drop_backing(HvGpuResource *r) {
    free(r->iov);
    r->iov = NULL;
    r->niov = 0;
}

/* Pixels that were on screen may still be read by the presenter for a moment (it works from a
   pointer it fetched at the start of its tick): free them a few releases later. */
static void retire_pixels(HvVirtioGpu *g, uint8_t *pixels) {
    unsigned i = g->retired_next++ % HV_GPU_RETIRED;
    free(g->retired[i]);
    g->retired[i] = pixels;
}

static void scanout_off(HvVirtioGpu *g) {
    if (!g->scanout_res) return;
    g->scanout_res = 0;
    hv_fb_display_set_scanout(g->fb, NULL, 0, 0, 0);
}

static void destroy(HvVirtioGpu *g, HvGpuResource *r) {
    if (g->scanout_res == r->id) scanout_off(g);
    retire_pixels(g, r->pixels);
    drop_backing(r);
    memset(r, 0, sizeof *r);
}

/* Copy `len` bytes at `off` of the guest's backing store into dst. */
static void backing_read(HvVirtioGpu *g, const HvGpuResource *r, uint64_t off, uint8_t *dst, uint32_t len) {
    /* Rows arrive in order, so start from where the last lookup ended. */
    uint32_t i = g->iov_hint < r->niov && r->iov[g->iov_hint].start <= off ? g->iov_hint : 0;
    while (i < r->niov && len) {
        const HvGpuIov *v = &r->iov[i];
        if (off >= v->start + v->len) {
            i++;
            continue;
        }
        uint64_t in = off - v->start;
        uint32_t n = (uint32_t)(v->len - in < len ? v->len - in : len);
        const uint8_t *src = hv_phys_ptr(g->vio.m, v->addr + in, n);
        if (!src) return;
        memcpy(dst, src, n);
        dst += n;
        off += n;
        len -= n;
    }
    g->iov_hint = i < r->niov ? i : 0;
}

/* ---- commands ---- */

static uint32_t cmd_create(HvVirtioGpu *g, const uint8_t *c) {
    uint32_t id = rd32(c + HDR), w = rd32(c + HDR + 8), h = rd32(c + HDR + 12);
    if (!id || find(g, id)) return RESP_ERR_INVALID_RESOURCE_ID;
    if (!w || !h || w > 8192 || h > 8192) return RESP_ERR_INVALID_PARAMETER;
    for (int i = 0; i < HV_GPU_MAX_RESOURCES; i++) {
        HvGpuResource *r = &g->res[i];
        if (r->id) continue;
        r->pixels = calloc((size_t)w * h, 4);
        if (!r->pixels) return RESP_ERR_OUT_OF_MEMORY;
        r->id = id;
        r->w = w;
        r->h = h;
        r->format = rd32(c + HDR + 4);
        return RESP_OK_NODATA;
    }
    return RESP_ERR_OUT_OF_MEMORY;
}

static uint32_t cmd_attach(HvVirtioGpu *g, HvVirtqElem *e, const uint8_t *c) {
    HvGpuResource *r = find(g, rd32(c + HDR));
    uint32_t n = rd32(c + HDR + 4);
    if (!r) return RESP_ERR_INVALID_RESOURCE_ID;
    if (r->iov || n == 0 || n > 16384) return RESP_ERR_UNSPEC;
    uint8_t *raw = malloc((size_t)n * 16);
    HvGpuIov *iov = calloc(n, sizeof *iov);
    if (!raw || !iov || hv_virtq_read(&g->vio, e, HDR + 8, raw, n * 16) != n * 16) {
        free(raw);
        free(iov);
        return RESP_ERR_UNSPEC;
    }
    uint64_t start = 0;
    for (uint32_t i = 0; i < n; i++) {
        iov[i].addr = rd64(raw + i * 16);
        iov[i].len = rd32(raw + i * 16 + 8);
        iov[i].start = start;
        start += iov[i].len;
    }
    free(raw);
    r->iov = iov;
    r->niov = n;
    return RESP_OK_NODATA;
}

static uint32_t cmd_transfer(HvVirtioGpu *g, const uint8_t *c) {
    uint32_t x = rd32(c + HDR), y = rd32(c + HDR + 4), w = rd32(c + HDR + 8), h = rd32(c + HDR + 12);
    uint64_t off = rd64(c + HDR + 16);
    HvGpuResource *r = find(g, rd32(c + HDR + 24));
    if (!r || !r->iov) return RESP_ERR_INVALID_RESOURCE_ID;
    if (x > r->w || y > r->h || w > r->w - x || h > r->h - y) return RESP_ERR_INVALID_PARAMETER;
    uint32_t stride = r->w * 4;
    for (uint32_t row = 0; row < h; row++)
        backing_read(g, r, off + (uint64_t)stride * row, r->pixels + (size_t)(y + row) * stride + (size_t)x * 4, w * 4);
    return RESP_OK_NODATA;
}

static uint32_t cmd_set_scanout(HvVirtioGpu *g, const uint8_t *c) {
    uint32_t scanout = rd32(c + HDR + 16), id = rd32(c + HDR + 20);
    if (scanout != 0) return RESP_ERR_INVALID_SCANOUT_ID;
    if (id == 0) {
        scanout_off(g);
        return RESP_OK_NODATA;
    }
    HvGpuResource *r = find(g, id);
    if (!r) return RESP_ERR_INVALID_RESOURCE_ID;
    g->scanout_res = id;
    hv_fb_display_set_scanout(g->fb, r->pixels, r->w, r->h, r->w * 4);
    return RESP_OK_NODATA;
}

static void control(HvVirtioGpu *g, HvVirtqElem *e) {
    static uint8_t c[64];
    uint8_t resp[HDR + 8 + 1024];
    memset(c, 0, sizeof c);
    memset(resp, 0, sizeof resp);
    uint32_t got = hv_virtq_read(&g->vio, e, 0, c, sizeof c);
    uint32_t type = got >= HDR ? rd32(c) : 0, len = HDR, code = RESP_ERR_UNSPEC;

    switch (type) {
    case CMD_GET_DISPLAY_INFO:
        code = RESP_OK_DISPLAY_INFO;
        len = HDR + 16 * 24;
        wr32(resp + HDR + 8, g->width);
        wr32(resp + HDR + 12, g->height);
        wr32(resp + HDR + 16, 1); /* enabled */
        break;
    case CMD_GET_EDID:
        if (rd32(c + HDR) != 0) {
            code = RESP_ERR_INVALID_SCANOUT_ID;
            break;
        }
        code = RESP_OK_EDID;
        len = HDR + 8 + 1024;
        wr32(resp + HDR, 128);
        build_edid(resp + HDR + 8, g->width, g->height);
        break;
    case CMD_RESOURCE_CREATE_2D: code = cmd_create(g, c); break;
    case CMD_RESOURCE_UNREF: {
        HvGpuResource *r = find(g, rd32(c + HDR));
        if (r) destroy(g, r);
        code = r ? RESP_OK_NODATA : RESP_ERR_INVALID_RESOURCE_ID;
        break;
    }
    case CMD_RESOURCE_ATTACH_BACKING: code = cmd_attach(g, e, c); break;
    case CMD_RESOURCE_DETACH_BACKING: {
        HvGpuResource *r = find(g, rd32(c + HDR));
        if (r) drop_backing(r);
        code = r ? RESP_OK_NODATA : RESP_ERR_INVALID_RESOURCE_ID;
        break;
    }
    case CMD_SET_SCANOUT: code = cmd_set_scanout(g, c); break;
    case CMD_TRANSFER_TO_HOST_2D: code = cmd_transfer(g, c); break;
    case CMD_RESOURCE_FLUSH:
        /* The presenter compares frames itself; nothing to do but answer. */
        code = find(g, rd32(c + HDR + 16)) ? RESP_OK_NODATA : RESP_ERR_INVALID_RESOURCE_ID;
        break;
    case CMD_GET_CAPSET_INFO:
        code = RESP_OK_CAPSET_INFO;
        len = HDR + 16;
        break;
    default:
        break;
    }
    if (g->log && (code >= RESP_ERR_UNSPEC || (type != CMD_TRANSFER_TO_HOST_2D && type != CMD_RESOURCE_FLUSH)))
        fprintf(stderr, "virtio-gpu: command %#x (%u bytes, arg %u) -> %#x, %u bytes back\n", type, got, rd32(c + HDR), code, len);

    wr32(resp, code);
    if (rd32(c + 4) & FLAG_FENCE) { /* a fenced command gets its fence back */
        wr32(resp + 4, FLAG_FENCE);
        memcpy(resp + 8, c + 8, 12);
    }
    uint32_t room = hv_virtq_writable(e);
    if (len > room) len = room;
    hv_virtq_write(&g->vio, e, 0, resp, len);
    hv_virtq_push(&g->vio, CTRLQ, e, len);
}

static void cursor(HvVirtioGpu *g, HvVirtqElem *e) {
    uint8_t c[HDR + 32] = {0};
    if (hv_virtq_read(&g->vio, e, 0, c, sizeof c) >= sizeof c && rd32(c + HDR) == 0) {
        int32_t x = (int32_t)rd32(c + HDR + 4), y = (int32_t)rd32(c + HDR + 8);
        uint32_t id = rd32(c + HDR + 16);
        if (rd32(c) == CMD_UPDATE_CURSOR) {
            HvGpuResource *r = find(g, id);
            if (r && r->w == HV_FB_CURSOR_SIZE && r->h == HV_FB_CURSOR_SIZE) {
                hv_fb_display_set_cursor(g->fb, r->pixels, rd32(c + HDR + 20), rd32(c + HDR + 24), x, y, 1);
                g->cursor_on = 1;
            } else {
                hv_fb_display_set_cursor(g->fb, NULL, 0, 0, x, y, 0);
                g->cursor_on = 0;
            }
        } else if (rd32(c) == CMD_MOVE_CURSOR) {
            /* A move with no resource hides the pointer. */
            if (id == 0) g->cursor_on = 0;
            hv_fb_display_set_cursor(g->fb, NULL, 0, 0, x, y, g->cursor_on);
        }
    }
    hv_virtq_push(&g->vio, CURSORQ, e, 0);
}

static void notify(HvVirtio *v, int q) {
    HvVirtioGpu *g = v->dev;
    if (g->log > 1) fprintf(stderr, "virtio-gpu: notify queue %d\n", q);
    static HvVirtqElem e;
    int any = 0;
    while (hv_virtq_pop(v, q, &e) > 0) {
        if (q == CTRLQ) control(g, &e);
        else cursor(g, &e);
        any = 1;
    }
    if (any) hv_virtio_interrupt(v);
}

static void on_reset(HvVirtio *v) {
    HvVirtioGpu *g = v->dev;
    if (!g) return;
    if (g->log) fprintf(stderr, "virtio-gpu: reset\n");
    for (int i = 0; i < HV_GPU_MAX_RESOURCES; i++)
        if (g->res[i].id) destroy(g, &g->res[i]);
    scanout_off(g);
    g->cursor_on = 0;
}

static void config_write(HvVirtio *v, uint32_t off, uint64_t val, unsigned size) {
    (void)size;
    if (off == 4) { /* events_clear */
        uint32_t ev = rd32(v->config) & ~(uint32_t)val;
        wr32(v->config, ev);
    }
}

/* The PCI subsystem ID decides who drives this device, and the firmware must not:
   - EDK2 binds a modern virtio device only if the ID is 0x40 or more. Its virtio-gpu driver makes
     a display with no framebuffer, and the Windows loader crashes when it finds one next to the
     boot framebuffer (the machine reboots in a loop).
   - Windows' driver (viogpudo) only installs on the ID QEMU uses, 0x1100.
   So firmware and boot loaders, which run at low, identity-mapped addresses, read the device type
   (16, what hv_virtio_init stored); an OS kernel, running in the upper half of the address space,
   reads 0x1100. */
#define SUBSYSTEM_ID_REG 0x2eu
#define SUBSYSTEM_ID_FOR_OS 0x1100u

static uint64_t subsystem_for_reader(HvPciDev *d, uint32_t reg, unsigned size, uint64_t value) {
    (void)d;
    if (!hv_self || !(hv_self->pc >> 63)) return value;
    for (unsigned i = 0; i < 2; i++) {
        uint32_t at = SUBSYSTEM_ID_REG + i;
        if (at < reg || at >= reg + size) continue;
        unsigned shift = (at - reg) * 8;
        value = (value & ~(0xffull << shift)) | ((uint64_t)((SUBSYSTEM_ID_FOR_OS >> (8 * i)) & 0xff) << shift);
    }
    return value;
}

void hv_virtio_gpu_set_size(HvVirtioGpu *g, uint32_t w, uint32_t h) {
    if (!g || w < 640 || h < 480) return;
    int changed = g->width != w || g->height != h;
    g->width = w;
    g->height = h;
    if (changed && (g->vio.status & 4)) { /* a driver is running: tell it the monitor changed */
        wr32(g->vio.config, rd32(g->vio.config) | EVENT_DISPLAY);
        hv_virtio_config_interrupt(&g->vio);
    }
}

HvVirtioGpu *hv_virtio_gpu_create(HvMachine *m, HvPcie *bus, HvFbDisplay *fb) {
    HvVirtioGpu *g = calloc(1, sizeof *g);
    HvVirtio *v = &g->vio;
    /* GPU device, class "other display controller" as QEMU's virtio-gpu-pci. The PCI subsystem
       ID it reports depends on who reads it: see subsystem_for_reader. */
    hv_virtio_init(v, m, 16, 0x038000, 2, F_EDID);
    hv_virtio_add_msix(v, 4); /* Windows' driver sets a configuration vector whether or not it asked for MSI */
    v->pci.config_read = subsystem_for_reader;
    v->dev = g;
    v->notify = notify;
    v->config_write = config_write;
    v->on_reset = on_reset;
    v->config_len = 16;
    wr32(v->config + 8, 1); /* one scanout */
    g->fb = fb;
    g->width = 1280;
    g->height = 800;
    g->log = getenv("HV_GPU_LOG") ? atoi(getenv("HV_GPU_LOG")) : 0;
    hv_pcie_attach(bus, &v->pci);
    return g;
}
