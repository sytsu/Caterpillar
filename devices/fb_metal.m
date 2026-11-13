#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <TargetConditionals.h>

#include <os/lock.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "fb_display.h"

static NSString *const kFbShaderSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VOut {\n"
     "    float4 pos [[position]];\n"
     "    float2 uv;\n"
     "};\n"
     "struct Place {\n"     /* where a quad goes in the drawable: half-size and centre, in clip space */
     "    float2 scale;\n"
     "    float2 centre;\n"
     "};\n"
     "vertex VOut fb_vs(uint vid [[vertex_id]], constant Place &place [[buffer(0)]]) {\n"
     "    const float2 quad[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
     "    const float2 uvs[4]  = { float2(0,1),   float2(1,1),  float2(0,0),  float2(1,0) };\n"
     "    VOut o;\n"
     "    o.pos = float4(quad[vid] * place.scale + place.centre, 0.0, 1.0);\n"
     "    o.uv  = uvs[vid];\n"
     "    return o;\n"
     "}\n"
     "fragment float4 fb_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
     "                      constant uint &nearest [[buffer(0)]]) {\n"
     "    constexpr sampler sl(mag_filter::linear, min_filter::linear, address::clamp_to_edge);\n"
     "    constexpr sampler sn(mag_filter::nearest, min_filter::linear, address::clamp_to_edge);\n"
     "    float4 c = nearest ? tex.sample(sn, in.uv) : tex.sample(sl, in.uv);\n"
     "    return float4(c.rgb, 1.0);\n"
     "}\n"
     /* The pointer image: straight alpha, blended over the picture. */
     "fragment float4 fb_cursor_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {\n"
     "    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);\n"
     "    return tex.sample(s, in.uv);\n"
     "}\n";

/* Presentation options, shared by every presenter (there is one display). */
static _Atomic int g_fb_fps = 60;      /* 60 or 30 */
static _Atomic int g_fb_nearest = 0;   /* 1 = nearest-neighbour magnification */
static _Atomic int g_fb_redraw = 0;    /* force the next tick to draw */

void hv_fb_metal_set_fps(int fps) {
    atomic_store(&g_fb_fps, fps <= 30 ? 30 : 60);
}

void hv_fb_metal_request_redraw(void) {
    atomic_store(&g_fb_redraw, 1);
}

void hv_fb_metal_set_nearest(int on) {
    atomic_store(&g_fb_nearest, on ? 1 : 0);
    atomic_store(&g_fb_redraw, 1);
}

/* Where the guest's desktop sits inside the framebuffer, when it is smaller than it.
   Windows keeps the desktop size it last used with the basic display driver, and the driver
   scales that into the framebuffer with black bars: at the sides if the desktop is narrower,
   above and below if it is wider. The app needs the rectangle to keep touches lined up. */
static os_unfair_lock g_content_lock = OS_UNFAIR_LOCK_INIT;
static uint32_t g_content[4];      /* x, y, w, h of the last stable finding; w == 0 means none */
static uint32_t g_content_seen[4];
static int g_content_streak;

#define CONTENT_STABLE_CHECKS 10   /* checks half a second apart */

static int px_black(const uint8_t *p) { return (p[0] | p[1] | p[2]) == 0; }

static int column_black(const uint8_t *px, uint32_t w, uint32_t h, uint32_t x) {
    for (uint32_t y = 0; y < h; y += 3)
        if (!px_black(px + ((size_t)y * w + x) * 4)) return 0;
    return 1;
}

static int row_black(const uint8_t *px, uint32_t w, uint32_t y) {
    const uint8_t *row = px + (size_t)y * w * 4;
    for (uint32_t x = 0; x < w; x += 3)
        if (!px_black(row + (size_t)x * 4)) return 0;
    return 1;
}

/* Bars on exactly two opposite sides, equal in size, and a picture in between: a scaled desktop.
   A boot logo or a dialog on a black screen has black on all four sides and is not one. */
static void find_content(const uint8_t *px, uint32_t w, uint32_t h, uint32_t out[4]) {
    out[0] = out[1] = out[2] = out[3] = 0;
    if (w < 320 || h < 240) return;
    uint32_t l = 0, r = 0, t = 0, b = 0;
    while (l < w / 2 && column_black(px, w, h, l)) l++;
    if (l >= w / 2) return; /* nothing on screen */
    while (r < w / 2 && column_black(px, w, h, w - 1 - r)) r++;
    while (t < h / 2 && row_black(px, w, t)) t++;
    while (b < h / 2 && row_black(px, w, h - 1 - b)) b++;

    int sides = l >= 16 && (l > r ? l - r : r - l) <= 2 && t == 0 && b == 0;
    int ends = t >= 16 && (t > b ? t - b : b - t) <= 2 && l == 0 && r == 0;
    if (!sides && !ends) return;
    out[0] = l;
    out[1] = t;
    out[2] = w - l - r;
    out[3] = h - t - b;
}

static void track_content(const uint8_t *px, uint32_t w, uint32_t h) {
    uint32_t now[4];
    find_content(px, w, h, now);
    os_unfair_lock_lock(&g_content_lock);
    if (memcmp(now, g_content_seen, sizeof now) == 0) {
        if (g_content_streak < CONTENT_STABLE_CHECKS) g_content_streak++;
    } else {
        memcpy(g_content_seen, now, sizeof now);
        g_content_streak = 0;
    }
    if (g_content_streak >= CONTENT_STABLE_CHECKS) memcpy(g_content, now, sizeof now);
    os_unfair_lock_unlock(&g_content_lock);
}

int hv_fb_metal_content_rect(uint32_t *x, uint32_t *y, uint32_t *w, uint32_t *h) {
    os_unfair_lock_lock(&g_content_lock);
    uint32_t c[4];
    memcpy(c, g_content, sizeof c);
    os_unfair_lock_unlock(&g_content_lock);
    if (c[2] == 0) return 0;
    *x = c[0];
    *y = c[1];
    *w = c[2];
    *h = c[3];
    return 1;
}

/* Rows compared and uploaded together. */
#define FB_BAND_ROWS 16u

@interface HvFbMetalPresenter : NSObject {
@public
    HvFbDisplay *fb;
    os_unfair_lock lock;
    CAMetalLayer *layer;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> pipeline;
    id<MTLRenderPipelineState> cursorPipeline;
    id<MTLTexture> texture;
    id<MTLTexture> cursorTexture;
    uint64_t cursorGen;
    uint32_t texW, texH;
    dispatch_source_t timer;
    _Atomic(uint64_t) framesPresented;
    uint8_t *shadow;      /* what the texture holds: texW x texH, tightly packed BGRX */
    uint64_t tickCount;
    CGSize lastDrawableSize;
}
- (instancetype)initWithDisplay:(HvFbDisplay *)display;
- (void)setTargetLayer:(CAMetalLayer *)newLayer;
- (void)tick;
@end

@implementation HvFbMetalPresenter

- (instancetype)initWithDisplay:(HvFbDisplay *)display {
    if ((self = [super init])) {
        fb = display;
        lock = OS_UNFAIR_LOCK_INIT;
        device = MTLCreateSystemDefaultDevice();
        if (device) {
            queue = [device newCommandQueue];
            NSError *err = nil;
            id<MTLLibrary> lib = [device newLibraryWithSource:kFbShaderSource options:nil error:&err];
            if (lib) {
                MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
                pd.vertexFunction = [lib newFunctionWithName:@"fb_vs"];
                pd.fragmentFunction = [lib newFunctionWithName:@"fb_fs"];
                pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
                pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];

                MTLRenderPipelineDescriptor *cd = [[MTLRenderPipelineDescriptor alloc] init];
                cd.vertexFunction = pd.vertexFunction;
                cd.fragmentFunction = [lib newFunctionWithName:@"fb_cursor_fs"];
                MTLRenderPipelineColorAttachmentDescriptor *ca = cd.colorAttachments[0];
                ca.pixelFormat = MTLPixelFormatBGRA8Unorm;
                ca.blendingEnabled = YES;
                ca.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                ca.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                ca.sourceAlphaBlendFactor = MTLBlendFactorOne;
                ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                cursorPipeline = [device newRenderPipelineStateWithDescriptor:cd error:&err];

                MTLTextureDescriptor *ctd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                               width:HV_FB_CURSOR_SIZE
                                                                                              height:HV_FB_CURSOR_SIZE
                                                                                           mipmapped:NO];
                ctd.usage = MTLTextureUsageShaderRead;
                cursorTexture = [device newTextureWithDescriptor:ctd];
            }
        }
    }
    return self;
}

- (void)dealloc {
    free(shadow);
}

- (void)setTargetLayer:(CAMetalLayer *)newLayer {
    os_unfair_lock_lock(&lock);
    layer = newLayer;
    lastDrawableSize = CGSizeZero;
    if (layer && device) {
        dispatch_block_t cfg = ^{
            newLayer.device = self->device;
            newLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            newLayer.framebufferOnly = YES;
        };
        if ([NSThread isMainThread]) cfg();
        else dispatch_async(dispatch_get_main_queue(), cfg);

        if (!timer) {
            dispatch_queue_t q = dispatch_queue_create("caterpillar.fbmetal", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
            timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 60, 2 * NSEC_PER_MSEC);
            __weak HvFbMetalPresenter *weakSelf = self;
            dispatch_source_set_event_handler(timer, ^{
                [weakSelf tick];
            });
            dispatch_resume(timer);
        }
    } else if (!layer && timer) {
        dispatch_source_cancel(timer);
        timer = nil;
    }
    os_unfair_lock_unlock(&lock);
}

/* Copy the rows that changed since the last tick into `shadow` and report their span.
   The guest draws while we read, so a row can change again right after it is compared; the
   next tick picks that up. Comparing everything (rather than sampling) is what keeps small
   changes, such as the mouse pointer or one typed letter, from being missed. */
static int sync_shadow(uint8_t *shadow, const uint8_t *px, uint32_t w, uint32_t h, uint32_t stride,
                       uint32_t *y0_out, uint32_t *y1_out) {
    size_t row_bytes = (size_t)w * 4;
    uint32_t y0 = h, y1 = 0;
    for (uint32_t y = 0; y < h; y += FB_BAND_ROWS) {
        uint32_t n = h - y < FB_BAND_ROWS ? h - y : FB_BAND_ROWS;
        const uint8_t *src = px + (size_t)y * stride;
        uint8_t *dst = shadow + (size_t)y * row_bytes;
        int changed = 0;
        if (stride == row_bytes) {
            changed = memcmp(src, dst, n * row_bytes) != 0;
            if (changed) memcpy(dst, src, n * row_bytes);
        } else {
            for (uint32_t r = 0; r < n; r++) {
                if (memcmp(src + (size_t)r * stride, dst + r * row_bytes, row_bytes)) {
                    memcpy(dst + r * row_bytes, src + (size_t)r * stride, row_bytes);
                    changed = 1;
                }
            }
        }
        if (changed) {
            if (y < y0) y0 = y;
            y1 = y + n;
        }
    }
    *y0_out = y0;
    *y1_out = y1;
    return y1 > y0;
}

- (void)tick {
    @autoreleasepool {
        tickCount++;
        if (atomic_load(&g_fb_fps) <= 30 && (tickCount & 1)) return;

        const uint8_t *px = NULL;
        uint32_t w = 0, h = 0, stride = 0;
        if (hv_fb_display_get_frame(fb, &px, &w, &h, &stride) != 0) return;

        os_unfair_lock_lock(&lock);
        CAMetalLayer *curLayer = layer;
        if (!curLayer || !device || !pipeline || !queue) {
            os_unfair_lock_unlock(&lock);
            return;
        }

        CGSize dsize = curLayer.drawableSize;
        if (dsize.width < 4 || dsize.height < 4) {
            os_unfair_lock_unlock(&lock);
            return;
        }

        BOOL redraw = !CGSizeEqualToSize(dsize, lastDrawableSize);
        if (atomic_exchange(&g_fb_redraw, 0)) redraw = YES;

        /* The display adapter's pointer: its own small image, drawn over the picture. */
        static uint8_t cursorPixels[HV_FB_CURSOR_SIZE * HV_FB_CURSOR_SIZE * 4];
        int cursorOn = 0;
        int32_t cursorX = 0, cursorY = 0;
        uint32_t hotX = 0, hotY = 0;
        uint64_t gen = hv_fb_display_get_cursor(fb, cursorPixels, &cursorOn, &cursorX, &cursorY, &hotX, &hotY);
        if (gen != cursorGen) {
            cursorGen = gen;
            redraw = YES;
            if (cursorTexture)
                [cursorTexture replaceRegion:MTLRegionMake2D(0, 0, HV_FB_CURSOR_SIZE, HV_FB_CURSOR_SIZE)
                                 mipmapLevel:0
                                   withBytes:cursorPixels
                                 bytesPerRow:HV_FB_CURSOR_SIZE * 4];
        }

        if (!texture || texW != w || texH != h) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:w
                                                                                         height:h
                                                                                      mipmapped:NO];
            td.usage = MTLTextureUsageShaderRead;
            texture = [device newTextureWithDescriptor:td];
            free(shadow);
            /* Start from a value the guest will not have (alpha 0x01), so the first compare uploads everything. */
            shadow = malloc((size_t)w * h * 4);
            if (!texture || !shadow) {
                texture = nil;
                free(shadow);
                shadow = NULL;
                texW = texH = 0;
                os_unfair_lock_unlock(&lock);
                return;
            }
            memset(shadow, 0x01, (size_t)w * h * 4);
            texW = w;
            texH = h;
        }

        uint32_t y0 = 0, y1 = 0;
        if (sync_shadow(shadow, px, w, h, stride, &y0, &y1)) {
            [texture replaceRegion:MTLRegionMake2D(0, y0, w, y1 - y0)
                       mipmapLevel:0
                         withBytes:shadow + (size_t)y0 * w * 4
                       bytesPerRow:(NSUInteger)w * 4];
            redraw = YES;
        }
        if (tickCount % 30 == 0) track_content(shadow, w, h);
        if (!redraw) {
            os_unfair_lock_unlock(&lock);
            return;
        }

        id<CAMetalDrawable> drawable = [curLayer nextDrawable];
        if (!drawable) {
            atomic_store(&g_fb_redraw, 1); /* the texture is ahead of the screen: draw on the next tick */
            os_unfair_lock_unlock(&lock);
            return;
        }

        float dstAspect = (float)(dsize.width / dsize.height);
        float srcAspect = (float)w / (float)h;
        float place[4] = {1.0f, 1.0f, 0.0f, 0.0f}; /* scale, centre: see Place in the shader */
        if (dstAspect > srcAspect) {
            place[0] = srcAspect / dstAspect;
        } else {
            place[1] = dstAspect / srcAspect;
        }

        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = drawable.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:pipeline];
        [enc setVertexBytes:place length:sizeof(place) atIndex:0];
        uint32_t nearest = (uint32_t)atomic_load(&g_fb_nearest);
        [enc setFragmentBytes:&nearest length:sizeof nearest atIndex:0];
        [enc setFragmentTexture:texture atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        if (cursorOn && cursorPipeline && cursorTexture) {
            /* The image's hot spot sits at (cursorX, cursorY) of the picture. */
            float half = (float)HV_FB_CURSOR_SIZE / 2.0f;
            float cx = ((float)cursorX - (float)hotX + half) / (float)w;
            float cy = ((float)cursorY - (float)hotY + half) / (float)h;
            float cplace[4] = {
                place[0] * (float)HV_FB_CURSOR_SIZE / (float)w, place[1] * (float)HV_FB_CURSOR_SIZE / (float)h,
                place[0] * (cx * 2.0f - 1.0f), place[1] * (1.0f - cy * 2.0f),
            };
            [enc setRenderPipelineState:cursorPipeline];
            [enc setVertexBytes:cplace length:sizeof(cplace) atIndex:0];
            [enc setFragmentTexture:cursorTexture atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }
        [enc endEncoding];
        [cb presentDrawable:drawable];
        [cb commit];

        lastDrawableSize = dsize;
        atomic_fetch_add_explicit(&framesPresented, 1, memory_order_relaxed);
        os_unfair_lock_unlock(&lock);
    }
}

@end

static HvFbMetalPresenter *ensure_presenter(HvFbDisplay *fb) {
    if (!fb) return nil;
    pthread_mutex_lock(&fb->mu);
    HvFbMetalPresenter *p = (__bridge HvFbMetalPresenter *)fb->metal;
    if (!p) {
        p = [[HvFbMetalPresenter alloc] initWithDisplay:fb];
        fb->metal = (__bridge_retained void *)p;
    }
    pthread_mutex_unlock(&fb->mu);
    return p;
}

void hv_fb_metal_set_layer(HvFbDisplay *fb, void *ca_metal_layer) {
    HvFbMetalPresenter *p = ensure_presenter(fb);
    if (!p) return;
    [p setTargetLayer:(__bridge CAMetalLayer *)ca_metal_layer];
}

uint64_t hv_fb_metal_frames(HvFbDisplay *fb) {
    if (!fb || !fb->metal) return 0;
    HvFbMetalPresenter *p = (__bridge HvFbMetalPresenter *)fb->metal;
    return atomic_load_explicit(&p->framesPresented, memory_order_relaxed);
}

int hv_fb_save_png(HvFbDisplay *fb, const char *path) {
    if (!fb || !path) return -1;
    const uint8_t *px = NULL;
    uint32_t w = 0, h = 0, stride = 0;
    if (hv_fb_display_get_frame(fb, &px, &w, &h, &stride) != 0) return -1;

    @autoreleasepool {
        size_t total = (size_t)stride * h;
        uint8_t *copy = malloc(total);
        if (!copy) return -1;
        memcpy(copy, px, total);
        /* Ensure alpha byte is 0xff (XRGB8888 leaves X=0x00) */
        for (uint32_t y = 0; y < h; y++) {
            uint8_t *row = copy + (size_t)y * stride;
            for (uint32_t x = 0; x < w; x++) row[x * 4 + 3] = 0xff;
        }
        /* Draw the adapter's pointer in, so a screenshot shows what the screen shows. */
        {
            static uint8_t cur[HV_FB_CURSOR_SIZE * HV_FB_CURSOR_SIZE * 4];
            int on = 0;
            int32_t cx = 0, cy = 0;
            uint32_t hx = 0, hy = 0;
            hv_fb_display_get_cursor(fb, cur, &on, &cx, &cy, &hx, &hy);
            for (uint32_t j = 0; on && j < HV_FB_CURSOR_SIZE; j++) {
                for (uint32_t i = 0; i < HV_FB_CURSOR_SIZE; i++) {
                    int64_t px_x = (int64_t)cx - hx + i, px_y = (int64_t)cy - hy + j;
                    if (px_x < 0 || px_y < 0 || px_x >= w || px_y >= h) continue;
                    const uint8_t *sp = cur + (j * HV_FB_CURSOR_SIZE + i) * 4;
                    uint8_t *dp = copy + (size_t)px_y * stride + (size_t)px_x * 4;
                    uint32_t a = sp[3];
                    for (int k = 0; k < 3; k++) dp[k] = (uint8_t)((sp[k] * a + dp[k] * (255 - a)) / 255);
                }
            }
        }

        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, copy, total, NULL);
        CGBitmapInfo bmi = kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst;
        CGImageRef img = CGImageCreate(w, h, 8, 32, stride, cs, bmi, prov, NULL, false, kCGRenderingIntentDefault);
        int rc = -1;
        if (img) {
            NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
            CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
            if (dst) {
                CGImageDestinationAddImage(dst, img, NULL);
                if (CGImageDestinationFinalize(dst)) rc = 0;
                CFRelease(dst);
            }
            CGImageRelease(img);
        }
        CGDataProviderRelease(prov);
        CGColorSpaceRelease(cs);
        free(copy);
        return rc;
    }
}
