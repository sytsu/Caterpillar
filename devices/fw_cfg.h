#ifndef WINVM_FW_CFG_H
#define WINVM_FW_CFG_H

#include <stddef.h>
#include <stdint.h>

#include "machine.h"

#define HV_FW_CFG_MAX_FILES 32

typedef void (*HvFwCfgWriteCb)(void *opaque, const uint8_t *data, uint32_t len);

typedef struct HvFwCfg {
    HvMachine *m;
    uint16_t cur_sel;
    uint32_t cur_off;
    uint32_t dma_hi;

    /* Standard fixed keys (0x0000..0x001f) */
    uint8_t fixed[0x20][64];
    uint32_t fixed_len[0x20];

    /* File directory (selector 0x0019, files at 0x0020 + i) */
    uint8_t *dir_blob;
    uint32_t dir_len;
    int nfiles;
    struct {
        char name[56];
        uint8_t *data;
        uint32_t len;
        int writable;
        HvFwCfgWriteCb on_write;
        void *write_opaque;
    } files[HV_FW_CFG_MAX_FILES];

    /* Preferred GOP mode (0 = leave the firmware's own mode list alone). See hv_fw_cfg_set_gop_mode. */
    uint32_t gop_w, gop_h;
    uint64_t gop_table_pa;    /* where the firmware's mode table was last found (0 = not yet) */
    uint32_t gop_patches;     /* how many times the table has been rewritten (once per firmware boot) */
} HvFwCfg;

HvFwCfg *hv_fw_cfg_create(HvMachine *m, uint64_t pa, uint16_t ncpus);
/* Add a read-only named file (copies `data`). */
int hv_fw_cfg_add_file(HvFwCfg *fc, const char *name, const void *data, uint32_t len);
/* Add a guest-writable named file (e.g. "etc/ramfb") with a callback fired when DMA writes it. */
int hv_fw_cfg_add_writable_file(HvFwCfg *fc, const char *name, uint32_t len, HvFwCfgWriteCb cb, void *opaque);

/* Ask for a W x H boot framebuffer. Stock EDK2 QemuRamfbDxe only offers 640x480, 800x600 and
   1024x768, and Windows keeps whatever GOP mode the firmware hands over, so the guest would
   otherwise be stuck at 4:3. The mode list is a plain table in the driver's data section: when the
   driver first talks to fw_cfg (before it sizes its framebuffer) we find that table next to the
   guest PC and rewrite every entry to W x H. Pass 0,0 to turn this off. Call before the VM starts. */
void hv_fw_cfg_set_gop_mode(HvFwCfg *fc, uint32_t w, uint32_t h);

#endif
