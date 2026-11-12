/* SPDX-License-Identifier: GPL-2.0-or-later */
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WinIOSStateCallback)(void);

@interface WinIOSBridge : NSObject

@property (class, nonatomic, readonly) WinIOSBridge *shared;

@property (nonatomic, readonly) BOOL isJITLive;
@property (nonatomic, readonly) BOOL isDebuggerAttached;
@property (nonatomic, readonly) BOOL isVMRunning;
@property (nonatomic, readonly) BOOL isUnpacking;
@property (nonatomic, readonly) double unpackProgress;
@property (nonatomic, readonly) NSString *jitStatusText;
@property (nonatomic, readonly) NSString *vmStatusText;
@property (nonatomic, readonly) uint32_t framebufferWidth;
@property (nonatomic, readonly) uint32_t framebufferHeight;
@property (nonatomic, readonly) uint64_t presentedFrames;
@property (nonatomic, readonly) uint64_t availableMemoryMB;
@property (nonatomic, readonly) BOOL usbKeyboardReady;
@property (nonatomic, readonly) BOOL usbTabletReady;
@property (nonatomic, readonly) uint64_t usbEventsDelivered;
@property (nonatomic, assign) BOOL useSafariForGuestLinks;

/* Machine settings. Set before -prepareAndStartWithLayer:; they are read when the VM is created. */
@property (nonatomic, assign) uint32_t preferredWidth;   /* boot framebuffer; 0 = firmware default (800x600) */
@property (nonatomic, assign) uint32_t preferredHeight;
@property (nonatomic, assign) uint64_t preferredRamMB;   /* 0 = as much as the device allows */
@property (nonatomic, assign) int preferredCPUs;         /* 0 = 4 */
@property (nonatomic, assign) BOOL diagnosticsEnabled;   /* write boot_status.txt and latest_screen.png to Documents */

/* Where the machine's files live (Documents/Machines/Win11 unless code.fd sits in Documents). */
@property (nonatomic, readonly) NSString *machineDirectory;
@property (nonatomic, readonly) BOOL hasFirmware;        /* code.fd in the machine folder, or the copy shipped in the app */
@property (nonatomic, readonly) BOOL usesBundledFirmware;
@property (nonatomic, readonly) BOOL hasDiskImage;       /* windows11.img or windows11.hvsparse */
@property (nonatomic, readonly) BOOL isSimulator;
@property (nonatomic, readonly) uint64_t configuredRamMB;
@property (nonatomic, readonly) int configuredCPUs;
@property (nonatomic, readonly) double guestIdlePercent; /* share of vCPU time spent idle, last 8 s */
@property (nonatomic, readonly) double uptimeSeconds;
@property (nonatomic, copy, nullable) WinIOSStateCallback onStateChanged;

- (nullable NSString *)takeGuestOpenURL;
- (BOOL)takeGuestOAuthDone;

- (void)installTrapGuard;
- (BOOL)tryAcquireJIT:(BOOL)detachAfter;

- (BOOL)hasProvisionedMachine;
- (BOOL)needsSparseUnpack;
- (void)prepareAndStartWithLayer:(nullable CAMetalLayer *)layer;
- (void)bindMetalLayer:(nullable CAMetalLayer *)layer;

- (void)updateScreenSize:(CGSize)size scale:(CGFloat)scale;
- (void)updateHingeStatus:(NSInteger)status angleDegrees:(double)angleDegrees;

- (void)sendTabletNormalizedX:(double)x y:(double)y buttons:(uint8_t)buttons wheel:(int8_t)wheel;
- (void)sendKeyHid:(uint8_t)usage down:(BOOL)down;
- (void)tapKeyHid:(uint8_t)usage;
- (void)sendKeyComboWithModifiers:(NSArray<NSNumber *> *)modifiers key:(uint8_t)usage;
- (void)sendWindowsKey;
- (void)sendCtrlAltDel;
- (void)sendAltTab;
- (void)sendEscape;
- (void)pressPowerButton;
- (void)flushDisks;
- (void)setDisplayFPS:(int)fps;
- (void)setNearestFilter:(BOOL)nearest;
- (BOOL)saveScreenshotToPath:(NSString *)path;
- (void)stopVM;

@end

NS_ASSUME_NONNULL_END
