#import <AppKit/AppKit.h>
#import "InterceptorPrivate.h"
#include "../ref_soft/r_local.h"
#include "../client/keys.h"
#include "swimp_pixels.h"
#include "in_openstep.h"

extern void Key_ClearStates(void);
extern void PSWait(void);

@interface QuakeView : NSView
{
    unsigned oldFlags;
}
@end

@interface QuakeWindow : NSWindow
@end

@implementation QuakeWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

NSWindow *vid_window_i;
NSView *vid_view_i;
static NSDirectBitmap *direct_bitmap;
static NSFramebuffer *screen_bitmap;
static NSRect screen_bounds;
static int screen_width, screen_height;
static int output_x, output_y, output_width, output_height;
static cvar_t *vid_directmapped;
static cvar_t *vid_xpos, *vid_ypos;
static unsigned char palette_rgba[1024];
static unsigned char palette_native[256][4];
static q2_pixel_layout pixel_layout;
static qboolean bitmap_dirty;
static unsigned frames_presented, locks_missed;
static int last_stride;
static char last_encoding[80];

static void VID_Info_f(void)
{
    if (screen_bitmap) {
        ri.Con_Printf(PRINT_ALL,
            "Interceptor: %dx%d fullscreen, framebuffer=%dx%d, output=%dx%d at %d,%d\n"
            "encoding=%s, bytes/pixel=%d, rowbytes=%d, frames=%u\n",
            vid.width, vid.height, screen_width, screen_height,
            output_width, output_height, output_x, output_y,
            last_encoding, Q2_PixelBytes(pixel_layout), last_stride,
            frames_presented);
        return;
    }
    ri.Con_Printf(PRINT_ALL,
        "OPENSTEP Interceptor: %dx%d, requested direct=%d, mapped=%d, buffered=%d\n"
        "encoding=%s, bytes/pixel=%d, rowbytes=%d, frames=%u, missed locks=%u\n",
        vid.width, vid.height, (int)vid_directmapped->value,
        direct_bitmap ? [direct_bitmap isDirectMapped] : 0,
        direct_bitmap ? [direct_bitmap isBuffered] : 0,
        last_encoding[0] ? last_encoding : "(not locked yet)",
        Q2_PixelBytes(pixel_layout), last_stride, frames_presented, locks_missed);
}

static void UpdateBitmap(void)
{
    NSRect rect;

    if (!direct_bitmap)
        return;
    rect = [vid_view_i convertRect:[vid_view_i bounds] toView:nil];
    /* updateForRect may enable mapping automatically. Apply the requested
     * presentation policy afterwards, especially for forced buffered mode. */
    [direct_bitmap updateForRect:rect inWindow:vid_window_i];
    [direct_bitmap setDirectMapped:vid_directmapped->value ? YES : NO];
    [direct_bitmap setBuffered:[direct_bitmap isDirectMapped] ? NO : YES];
    bitmap_dirty = false;
    vid_directmapped->modified = false;
}

int SWimp_Init(void *hInstance, void *wndProc)
{
    if (!NSApp) {
        [NSApplication sharedApplication];
        [NSApp finishLaunching];
    }
    vid_directmapped = ri.Cvar_Get("vid_directmapped", "1", CVAR_ARCHIVE);
    vid_xpos = ri.Cvar_Get("vid_xpos", "100", CVAR_ARCHIVE);
    vid_ypos = ri.Cvar_Get("vid_ypos", "100", CVAR_ARCHIVE);
    ri.Cmd_AddCommand("vid_info", VID_Info_f);
    return true;
}

void SWimp_Shutdown(void)
{
    IN_SetFullscreen(false);
    IN_DeactivateMouse();
    if (vid_view_i) {
        [[NSNotificationCenter defaultCenter] removeObserver:vid_view_i
            name:NSApplicationDidResignActiveNotification object:NSApp];
        [[NSNotificationCenter defaultCenter] removeObserver:vid_view_i
            name:NSApplicationDidBecomeActiveNotification object:NSApp];
    }
    /* Detach delegates and release the bitmap before its window. AppKit
     * notifications must never call into a view that has been freed. */
    if (vid_window_i) {
        [vid_window_i setDelegate:nil];
        [vid_window_i makeFirstResponder:nil];
    }
    if (direct_bitmap) {
        /* OPENSTEP's dealloc does not unregister the intercepted rectangle.
         * setDirectMapped:NO removes it from the WindowServer/client list
         * under the library's notification lock before the target is freed. */
        [direct_bitmap setDirectMapped:NO];
        [direct_bitmap release];
        direct_bitmap = nil;
    }
    if (screen_bitmap) {
        [screen_bitmap release];
        screen_bitmap = nil;
    }
    if (vid_window_i) {
        [vid_window_i orderOut:nil];
        [vid_window_i close];
        [vid_window_i release];
        vid_window_i = nil;
    }
    if (vid_view_i) {
        [vid_view_i release];
        vid_view_i = nil;
    }
    if (vid.buffer) {
        free(vid.buffer);
        vid.buffer = NULL;
    }
    pixel_layout = Q2_PIXEL_UNSUPPORTED;
    last_stride = 0;
    last_encoding[0] = 0;
    bitmap_dirty = false;
}

static NSFramebuffer *OpenFramebuffer(NSRect *bounds)
{
    NSFramebuffer *bitmap;
    id number;
    q2_pixel_layout layout;
    int width, height, bytes;

    number = [[[NSScreen mainScreen] deviceDescription] objectForKey:@"NSScreenNumber"];
    bitmap = [[NSFramebuffer alloc] initFromScreen:number ? [number intValue] : 0
                                  andMapIfPossible:YES];
    /* 4.2's screenBounds: takes a rectangle by value, not an output pointer. */
    width = [bitmap pixelsWide];
    height = [bitmap pixelsHigh];
    *bounds = [[NSScreen mainScreen] frame];
    layout = Q2_PixelLayout([[bitmap pixelEncoding] cString]);
    bytes = Q2_PixelBytes(layout);
    if (!bitmap || ![bitmap isMappable] || ![bitmap data] || !bytes ||
        width <= 0 || height <= 0 || width > 16384 || height > 16384 ||
        width != bounds->size.width || height != bounds->size.height ||
        [bitmap bytesPerRow] / bytes < width) {
        [bitmap release];
        ri.Con_Printf(PRINT_ALL, "Fullscreen framebuffer unavailable; using a window.\n");
        return nil;
    }
    return bitmap;
}

rserr_t SWimp_SetMode(int *pwidth, int *pheight, int mode, qboolean fullscreen)
{
    int width, height;
    byte *new_buffer;
    NSFramebuffer *new_screen = nil;
    NSRect rect, new_bounds;

    /* Reject invalid requests before touching the working window/buffer. */
    if (!ri.Vid_GetModeInfo(&width, &height, mode))
        return rserr_invalid_mode;
    new_buffer = calloc(width, height);
    if (!new_buffer)
        ri.Sys_Error(ERR_FATAL, "OPENSTEP: cannot allocate %dx%d video buffer", width, height);
    if (fullscreen)
        new_screen = OpenFramebuffer(&new_bounds);

    Key_ClearStates();
    SWimp_Shutdown();
    vid.buffer = new_buffer;
    vid.rowbytes = width;
    *pwidth = width;
    *pheight = height;
    screen_bitmap = new_screen;
    if (screen_bitmap) {
        screen_bounds = new_bounds;
        screen_width = screen_bounds.size.width;
        screen_height = screen_bounds.size.height;
        rect = screen_bounds;
        if (screen_width * height <= screen_height * width) {
            output_width = screen_width;
            output_height = screen_width * height / width;
        } else {
            output_height = screen_height;
            output_width = screen_height * width / height;
        }
        if (output_width < 1) output_width = 1;
        if (output_height < 1) output_height = 1;
        output_x = (screen_width - output_width) / 2;
        output_y = (screen_height - output_height) / 2;
    } else {
        rect = NSMakeRect(vid_xpos->value, vid_ypos->value, width, height);
    }
    vid_window_i = [[QuakeWindow alloc] initWithContentRect:rect
        styleMask:screen_bitmap ? NSBorderlessWindowMask :
            (NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask)
        backing:screen_bitmap ? NSBackingStoreNonretained : NSBackingStoreRetained
        defer:NO];
    if (!vid_window_i)
        ri.Sys_Error(ERR_FATAL, "OPENSTEP: cannot create video window");
    [vid_window_i setReleasedWhenClosed:NO];
    [vid_window_i setTitle:@"Quake II"];
    if (screen_bitmap) {
        [vid_window_i setLevel:NSMainMenuWindowLevel + 1];
        /* Hide after our current framebuffer write finishes, not mid-frame. */
        [vid_window_i setHidesOnDeactivate:NO];
    }

    rect.origin.x = rect.origin.y = 0;
    vid_view_i = [[QuakeView alloc] initWithFrame:rect];
    [vid_window_i setContentView:vid_view_i];
    [vid_window_i setDelegate:vid_view_i];
    [vid_window_i makeFirstResponder:vid_view_i];
    if (screen_bitmap) {
        [[NSNotificationCenter defaultCenter] addObserver:vid_view_i
            selector:@selector(applicationDidResignActive:)
            name:NSApplicationDidResignActiveNotification object:NSApp];
        [[NSNotificationCenter defaultCenter] addObserver:vid_view_i
            selector:@selector(applicationDidBecomeActive:)
            name:NSApplicationDidBecomeActiveNotification object:NSApp];
    }
    [NSApp activateIgnoringOtherApps:YES];
    [vid_window_i makeKeyAndOrderFront:nil];
    [vid_window_i display];
    PSWait();

    if (screen_bitmap) {
        IN_SetFullscreen(true);
        bitmap_dirty = true;
    } else {
        rect = [vid_view_i convertRect:[vid_view_i bounds] toView:nil];
        direct_bitmap = [[NSDirectBitmap alloc] initForRect:rect inWindow:vid_window_i];
        if (!direct_bitmap)
            ri.Sys_Error(ERR_FATAL, "OPENSTEP: Interceptor NSDirectBitmap unavailable");
        UpdateBitmap();
    }
    ri.Vid_NewWindow(width, height);
    ri.Con_Printf(PRINT_ALL, "Interceptor: mode %d, %dx%d %s\n", mode, width, height,
                 screen_bitmap ? "fullscreen" : "windowed");

    /* The software renderer requires a valid framebuffer even on this return. */
    return fullscreen && !screen_bitmap ? rserr_invalid_fullscreen : rserr_ok;
}

void SWimp_SetPalette(const unsigned char *palette)
{
    if (palette)
        memcpy(palette_rgba, palette, sizeof(palette_rgba));
    Q2_PixelPalette(pixel_layout, palette_rgba, palette_native);
}

void SWimp_EndFrame(void)
{
    id encoding;
    const char *name;
    q2_pixel_layout layout;
    byte *data;
    int stride, ok, y, bytes;

    if ((!direct_bitmap && !screen_bitmap) || !vid.buffer || [vid_window_i isMiniaturized])
        return;
    if (screen_bitmap) {
        /* Unlike NSDirectBitmap, NSFramebuffer does not clip other windows. */
        IN_Frame();
        if (![NSApp isActive] || ![vid_window_i isKeyWindow] || ![vid_window_i isVisible])
            return;
        encoding = [screen_bitmap pixelEncoding];
        data = (byte *)[screen_bitmap data];
        stride = [screen_bitmap bytesPerRow];
    } else {
        if (bitmap_dirty || vid_directmapped->modified)
            UpdateBitmap();
        if (![direct_bitmap tryLockBitmap]) {
            locks_missed++;
            PSWait();
            return;
        }
        encoding = [direct_bitmap pixelEncoding];
        data = (byte *)[direct_bitmap data];
        stride = [direct_bitmap bytesPerRow];
    }

    /* Format and stride can change between mapped and buffered presentation. */
    name = encoding ? [encoding cString] : "(null)";
    layout = Q2_PixelLayout(name);
    if (layout != pixel_layout) {
        pixel_layout = layout;
        Q2_PixelPalette(layout, palette_rgba, palette_native);
    }
    strncpy(last_encoding, name, sizeof(last_encoding) - 1);
    last_encoding[sizeof(last_encoding) - 1] = 0;
    last_stride = stride;
    if (screen_bitmap) {
        bytes = Q2_PixelBytes(layout);
        if (!data || !bytes || stride / bytes < screen_width)
            ri.Sys_Error(ERR_FATAL, "Unusable fullscreen framebuffer");
        if (bitmap_dirty) {
            for (y = 0; y < screen_height; y++)
                memset(data + y * stride, 0, screen_width * bytes);
            bitmap_dirty = false;
        }
        ok = Q2_PixelBlitScaled(data + output_y * stride + output_x * bytes,
            stride, output_width, output_height, vid.buffer, vid.rowbytes,
            vid.width, vid.height, layout, palette_native);
    } else {
        ok = Q2_PixelBlit(data, stride, vid.buffer, vid.rowbytes,
                         vid.width, vid.height, layout, palette_native);
        [direct_bitmap unlockBitmap];
    }
    if (!ok)
        ri.Sys_Error(ERR_FATAL, "OPENSTEP: unusable Interceptor bitmap (%s, rowbytes=%d)",
                     last_encoding, stride);
    if (direct_bitmap)
        [direct_bitmap flushIn:[vid_view_i bounds]];
    PSWait();
    frames_presented++;
    if (frames_presented == 1)
        VID_Info_f();
}

void SWimp_AppActivate(qboolean active)
{
    if (!active) {
        if (screen_bitmap) {
            [vid_window_i orderOut:nil];
            PSWait();
        }
        IN_DeactivateMouse();
        Key_ClearStates();
    }
    bitmap_dirty = true;
}

static int TranslateKey(NSEvent *event)
{
    NSString *characters;
    unsigned ch;

    characters = [event charactersIgnoringModifiers];
    if (![characters length])
        return -1;
    ch = [characters characterAtIndex:0];
    switch (ch) {
    case 0xf700: return K_UPARROW;
    case 0xf701: return K_DOWNARROW;
    case 0xf702: return K_LEFTARROW;
    case 0xf703: return K_RIGHTARROW;
    case 0xf727: return K_INS;
    case 0xf728: return K_DEL;
    case 0xf729: return K_HOME;
    case 0xf72b: return K_END;
    case 0xf72c: return K_PGUP;
    case 0xf72d: return K_PGDN;
    case 0xf730: return K_PAUSE;
    case 127: return K_BACKSPACE;
    case 3: return K_ENTER;
    }
    if (ch >= 0xf704 && ch <= 0xf70f)
        return K_F1 + ch - 0xf704;
    if (ch >= 'A' && ch <= 'Z')
        ch += 'a' - 'A';
    return ch < 256 ? ch : -1;
}

qboolean SWimp_HandleKeyEvent(NSEvent *event)
{
    int type = [event type];

    /* Handle both Option and Command. AppKit consumes Command key-downs
     * as menu shortcuts before they reach the view's keyDown: method. */
    if ((type != NSKeyDown && type != NSKeyUp) ||
        ![NSApp isActive] || ![vid_window_i isKeyWindow] ||
        !([event modifierFlags] & (NSAlternateKeyMask | NSCommandKeyMask)) ||
        TranslateKey(event) != K_ENTER)
        return false;
    if (type == NSKeyDown && ![event isARepeat])
        ri.Cvar_SetValue("vid_fullscreen", !vid_fullscreen->value);
    return true;
}

@implementation QuakeView
- (void)applicationDidResignActive:(NSNotification *)note
{
    SWimp_AppActivate(false);
}
- (void)applicationDidBecomeActive:(NSNotification *)note
{
    if (screen_bitmap)
        [vid_window_i makeKeyAndOrderFront:nil];
    bitmap_dirty = true;
}
- (BOOL)acceptsFirstResponder
{
    return YES;
}
- (void)drawRect:(NSRect)rect
{
    /* Presentation occurs after rendering, outside AppKit's draw callback. */
    bitmap_dirty = true;
}
- (BOOL)windowShouldClose:(id)sender
{
    ri.Cmd_ExecuteText(EXEC_APPEND, "quit\n");
    return NO;
}
- (void)windowDidMove:(NSNotification *)note
{
    NSRect rect;
    if (screen_bitmap)
        return;
    IN_DeactivateMouse();
    rect = [NSWindow contentRectForFrameRect:[vid_window_i frame]
                                 styleMask:[vid_window_i styleMask]];
    ri.Cvar_SetValue("vid_xpos", rect.origin.x);
    ri.Cvar_SetValue("vid_ypos", rect.origin.y);
    bitmap_dirty = true;
}
- (void)windowDidBecomeKey:(NSNotification *)note
{
    bitmap_dirty = true;
}
- (void)windowDidResignKey:(NSNotification *)note
{
    IN_DeactivateMouse();
    bitmap_dirty = true;
    oldFlags = 0;
    Key_ClearStates();
}
- (void)windowDidDeminiaturize:(NSNotification *)note
{
    bitmap_dirty = true;
}
- (void)windowWillMiniaturize:(NSNotification *)note
{
    IN_DeactivateMouse();
    oldFlags = 0;
    Key_ClearStates();
}
- (void)mouseDown:(NSEvent *)event
{
    IN_MouseButton(0, true);
}
- (void)mouseUp:(NSEvent *)event
{
    IN_MouseButton(0, false);
}
- (void)rightMouseDown:(NSEvent *)event
{
    IN_MouseButton(1, true);
}
- (void)rightMouseUp:(NSEvent *)event
{
    IN_MouseButton(1, false);
}
- (void)keyDown:(NSEvent *)event
{
    int key;
    key = TranslateKey(event);
    if (key >= 0)
        Key_Event(key, true, Sys_Milliseconds());
}
- (void)keyUp:(NSEvent *)event
{
    int key;
    key = TranslateKey(event);
    if (key >= 0)
        Key_Event(key, false, Sys_Milliseconds());
}
- (void)flagsChanged:(NSEvent *)event
{
    unsigned flags, mask;
    int i;
    static unsigned masks[] = {NSShiftKeyMask, NSControlKeyMask,
                               NSAlternateKeyMask | NSCommandKeyMask};
    static int keys[] = {K_SHIFT, K_CTRL, K_ALT};
    flags = [event modifierFlags];
    for (i = 0; i < 3; i++) {
        mask = masks[i];
        if (!!(flags & mask) != !!(oldFlags & mask))
            Key_Event(keys[i], (flags & mask) != 0, Sys_Milliseconds());
    }
    oldFlags = flags;
}
@end
