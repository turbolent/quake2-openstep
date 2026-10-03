Quake II 3.21

Requirements
------------
OPENSTEP 4.2 for Intel, with its AppKit, Foundation, SoundKit and Interceptor
frameworks. No compiler, extra renderer, or separate game library is
needed to run the application. Sound requires a working SoundKit output device.
IntelHDA hardware should use driver 0.19 or later.

Installation
------------
Extract the application into a directory you own, such as ~/Apps. In Workspace,
open quake2.app as a folder and open its baseq2 folder. Copy your Quake II .pak
files there, including pak0.pak. Either the original game or demo data can be
used; do not combine the two. For the full game, also copy its loose assets and
video files if desired. Game data is not included in the archive.

Double-click quake2.app to play. Configuration and saved games are stored in
the application's baseq2 directory, so the application must remain writable.
Move the whole application if you want to relocate it. Start a new game when
upgrading from a development build; saves are not portable between builds.

Controls and settings
---------------------
Use the game's menus to configure controls. Escape releases the mouse to the
menus; quitting restores the desktop cursor. The initial window is 640x480.
Option-Enter toggles fullscreen. Fullscreen uses the desktop resolution and
scales the selected rendering resolution to fit, preserving its aspect ratio.
Black bars fill any remaining space. Switching applications releases the screen.

Enter these commands in the console (the backtick key):
  vid_mode 3        640x480
  vid_mode 6        1024x768
  vid_mode 8        1280x960
  vid_fullscreen 1  Fullscreen
  vid_fullscreen 0  Windowed
  cl_showfps 1      Show frame rate
  s_khz 44; snd_restart     Request 44.1 kHz sound
  s_khz 22; snd_restart     Request 22.05 kHz sound

Sound uses 16-bit stereo output at a rate supported by the device. The sound
quality menu may select 22.05 kHz; use the console for 44.1 kHz. Windowed and
fullscreen software rendering are supported. CD audio, OpenGL, and loadable
game mods are not included in this build.

Source and build
----------------
The matching source archive accompanies the binary distribution. The engine
source is licensed under GPL version 2 or later; see COPYING. Game data remains
under its own license.

On OPENSTEP with GCC 4.2 and GNU make installed:
  cd openstep
  gnumake -f Makefile.openstep

The result is output/quake2.app. Build flags retain debug information and use
-O2 with -fno-strict-aliasing and -fwrapv for the legacy engine code. Do not
change optimization flags without rebuilding all objects.

Build and package both the application and corresponding source on OPENSTEP:
  cd openstep
  gnumake -f Makefile.openstep package

This creates output/quake2.app.tar.gz and output/quake2-source.tar.gz using
/bin/sh, tar, gzip and the native file tools. Python is not required. Only the
packaged executable has its debug symbols removed; the build keeps its symbols.

The package-app and package-source targets can also be used individually.
To package an existing build without invoking make:
  /bin/sh package.sh app output/quake2.app output/quake2.app.tar.gz
  /bin/sh package.sh source output/quake2-source.tar.gz

The application archive includes only the executable, icon, documentation and
initial configuration. It excludes local game data, saved games and logs.
