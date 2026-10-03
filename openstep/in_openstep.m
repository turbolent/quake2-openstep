/*
Copyright (C) 1997-2001 Id Software, Inc.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
*/

#import <AppKit/AppKit.h>
#include "../client/client.h"
#include "in_openstep.h"

extern NSView *vid_view_i;
extern NSWindow *vid_window_i;
extern void PSsetmouse(float x, float y);
extern void PScurrentmouse(int window, float *x, float *y);
extern void PShidecursor(void);
extern void PSshowcursor(void);
extern void PSWait(void);

cvar_t *in_mouse, *in_joystick;
static cvar_t *m_filter;
static qboolean initialized, mouse_active, cursor_hidden, mlooking;
static qboolean fullscreen;
static unsigned mouse_buttons;
static NSPoint mouse_origin;
static float old_mouse_x, old_mouse_y;
static double total_x, total_y;

static void IN_ShowCursor(void)
{
    if (cursor_hidden) {
        PSshowcursor();
        /* Complete the display-server request before exit can close DPS. */
        PSWait();
        cursor_hidden = false;
    }
}

static qboolean IN_WindowActive(void)
{
    return vid_window_i && vid_view_i
        && [NSApp isActive] && [vid_window_i isKeyWindow]
        && [vid_window_i isVisible] && ![vid_window_i isMiniaturized];
}

static void IN_UpdateCursor(void)
{
    static qboolean exit_registered;

    /* Raw framebuffer drawing also needs the cursor hidden in game menus. */
    if (mouse_active || (fullscreen && IN_WindowActive())) {
        if (!cursor_hidden) {
            /* Run before AppKit closes its display-server connection. */
            if (!exit_registered) {
                atexit(IN_ShowCursor);
                exit_registered = true;
            }
            PShidecursor();
            PSWait();
            cursor_hidden = true;
        }
    } else {
        IN_ShowCursor();
    }
}

void IN_SetFullscreen(qboolean enabled)
{
    fullscreen = enabled;
    IN_UpdateCursor();
}

static qboolean IN_CanCapture(void)
{
    return initialized && in_mouse->value && IN_WindowActive()
        && cls.state == ca_active && cl.refresh_prepped
        && cls.key_dest == key_game && !cls.disable_screen;
}

/* PSsetmouse uses the focused view's coordinates; PScurrentmouse returns
 * window coordinates. Read back the warp to account for pixel rounding. */
static NSPoint IN_MousePosition(void)
{
    NSPoint point;
    PScurrentmouse([vid_window_i windowNumber], &point.x, &point.y);
    return [vid_view_i convertPoint:point fromView:nil];
}

static void IN_CenterMouse(void)
{
    NSRect bounds;
    bounds = [vid_view_i bounds];
    PSsetmouse(bounds.origin.x + bounds.size.width * 0.5,
               bounds.origin.y + bounds.size.height * 0.5);
    mouse_origin = IN_MousePosition();
}

void IN_DeactivateMouse(void)
{
    unsigned buttons;
    int i;

    mouse_active = false;
    buttons = mouse_buttons;
    mouse_buttons = 0;
    for (i = 0; i < 2; i++)
        if (buttons & (1 << i))
            Key_Event(K_MOUSE1 + i, false, Sys_Milliseconds());
    IN_UpdateCursor();
    old_mouse_x = old_mouse_y = 0;
    mlooking = false;
}

void IN_ActivateMouse(void)
{
    if (mouse_active || !IN_CanCapture())
        return;
    [vid_view_i lockFocus];
    IN_CenterMouse();
    [vid_view_i unlockFocus];
    mouse_active = true;
    IN_UpdateCursor();
    old_mouse_x = old_mouse_y = 0;
}

void IN_Frame(void)
{
    if (IN_CanCapture())
        IN_ActivateMouse();
    else
        IN_DeactivateMouse();
}

void IN_Activate(qboolean active)
{
    if (active)
        IN_Frame();
    else
        IN_DeactivateMouse();
}

void IN_MouseButton(int button, qboolean down)
{
    unsigned mask;

    /* A focus-acquiring click must not also fire a weapon. */
    if (!mouse_active || !IN_CanCapture() || button < 0 || button >= 2)
        return;
    mask = 1 << button;
    if (!!(mouse_buttons & mask) == !!down)
        return;
    if (down)
        mouse_buttons |= mask;
    else
        mouse_buttons &= ~mask;
    Key_Event(K_MOUSE1 + button, down, Sys_Milliseconds());
}

void IN_Move(usercmd_t *cmd)
{
    NSPoint point;
    float dx, dy, mouse_x, mouse_y;

    /* Console commands and focus events may have changed capture this frame. */
    IN_Frame();
    if (!mouse_active)
        return;
    [vid_view_i lockFocus];
    point = IN_MousePosition();
    dx = point.x - mouse_origin.x;
    dy = mouse_origin.y - point.y;
    if (dx || dy)
        IN_CenterMouse();
    [vid_view_i unlockFocus];

    total_x += dx;
    total_y += dy;
    mouse_x = m_filter->value ? (dx + old_mouse_x) * 0.5 : dx;
    mouse_y = m_filter->value ? (dy + old_mouse_y) * 0.5 : dy;
    old_mouse_x = dx;
    old_mouse_y = dy;
    mouse_x *= sensitivity->value;
    mouse_y *= sensitivity->value;

    if ((in_strafe.state & 1) || (lookstrafe->value && mlooking))
        cmd->sidemove += m_side->value * mouse_x;
    else
        cl.viewangles[YAW] -= m_yaw->value * mouse_x;
    if ((mlooking || freelook->value) && !(in_strafe.state & 1))
        cl.viewangles[PITCH] += m_pitch->value * mouse_y;
    else
        cmd->forwardmove -= m_forward->value * mouse_y;
    /* CL_FinishMove applies the engine's pitch limits and angle offsets. */
}

static void IN_MLookDown(void)
{
    mlooking = true;
}

static void IN_MLookUp(void)
{
    mlooking = false;
    if (!freelook->value && lookspring->value)
        IN_CenterView();
}

static void IN_Info_f(void)
{
    Com_Printf("Mouse: enabled=%d available=%d captured=%d hidden=%d buttons=%u "
               "motion=%.0f,%.0f yaw=%.3f pitch=%.3f\n",
               in_mouse->value != 0, initialized, mouse_active, cursor_hidden,
               mouse_buttons, total_x, total_y, cl.viewangles[YAW], cl.viewangles[PITCH]);
}

void IN_Init(void)
{
    in_mouse = Cvar_Get("in_mouse", "1", CVAR_ARCHIVE);
    in_joystick = Cvar_Get("in_joystick", "0", CVAR_ARCHIVE);
    m_filter = Cvar_Get("m_filter", "0", CVAR_ARCHIVE);
    Cmd_AddCommand("+mlook", IN_MLookDown);
    Cmd_AddCommand("-mlook", IN_MLookUp);
    Cmd_AddCommand("in_info", IN_Info_f);
    initialized = !COM_CheckParm("-nomouse");
}

void IN_Shutdown(void)
{
    fullscreen = false;
    IN_DeactivateMouse();
    initialized = false;
    Cmd_RemoveCommand("+mlook");
    Cmd_RemoveCommand("-mlook");
    Cmd_RemoveCommand("in_info");
}

void IN_Commands(void)
{
}
