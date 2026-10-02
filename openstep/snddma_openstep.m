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

#import <SoundKit/NXSoundOut.h>
#import <SoundKit/NXPlayStream.h>
#include "../client/client.h"
#include "../client/snd_loc.h"

/* Keep page-aligned PCM copies until SoundKit completes each submission. */
#define BLOCK_FRAMES 1024
#define BLOCK_BYTES (BLOCK_FRAMES * 4)
#define SOUND_BLOCKS 8
#define SOUND_FRAMES (BLOCK_FRAMES * SOUND_BLOCKS * 2)

extern int soundtime;
static NXSoundOut *sound_device;
static NXPlayStream *sound_stream;
static id sound_delegate;
static qboolean sound_ready, painting, next_valid, info_registered;
static qboolean stream_paused;
static unsigned processed_bytes, submitted_bytes;
static unsigned next_tag, underruns;
static int next_frame, next_block;
static vm_address_t block_memory;
static vm_size_t block_stride, block_memory_size;
static struct {
    unsigned tag, bytes;
    qboolean busy;
} blocks[SOUND_BLOCKS];

@interface QuakeSoundDelegate : NSObject
@end

/* SoundKit delivers these on the main event loop, alongside AppKit events.
 * Count completed PCM, not wall time, so a drained queue never replays stale
 * mixer data. Tags remain unique across aborts and sound restarts. */
@implementation QuakeSoundDelegate
- (void)soundStream:(id)sender didCompleteBuffer:(int)tag
{
    int i;
    if (sender != sound_stream || !sound_ready)
        return;
    for (i = 0; i < SOUND_BLOCKS; i++)
        if (blocks[i].busy && blocks[i].tag == (unsigned)tag) {
            processed_bytes += blocks[i].bytes;
            blocks[i].busy = false;
            break;
        }
}
- (void)soundStreamDidUnderrun:(id)sender
{
    if (sender == sound_stream && sound_ready)
        underruns++;
}
- (void)soundStreamDidAbort:(id)sender deviceReserved:(BOOL)reserved
{
    if (sender == sound_stream && reserved)
        sound_ready = false;
}
@end

static void SoundError(const char *operation, NXSoundDeviceError error)
{
    Com_Printf("SoundKit: %s failed (%d: %s)\n", operation, error,
        [[NXSoundDevice textForError:error] cString]);
}

static qboolean SoundPause(void)
{
    NXSoundDeviceError error;

    error = [sound_stream pauseAtTime:NX_SOUNDSTREAM_TIME_NULL];
    if (error != NX_SoundDeviceErrorNone) {
        SoundError("stream pause", error);
        SNDDMA_Shutdown();
        return false;
    }
    stream_paused = true;
    return true;
}

static int SoundRate(void)
{
    const float *rates;
    unsigned count, i;
    float low, high;
    NXSoundDeviceError error;
    qboolean supports22, supports44;
    int rate;

    supports22 = supports44 = false;
    if ([sound_device acceptsContinuousStreamSamplingRates]) {
        error = [sound_device getStreamSamplingRatesLow:&low high:&high];
        if (error == NX_SoundDeviceErrorNone) {
            supports22 = low <= 22050 && high >= 22050;
            supports44 = low <= 44100 && high >= 44100;
        }
    } else {
        rates = NULL;
        count = 0;
        error = [sound_device getStreamSamplingRates:&rates count:&count];
        if (error == NX_SoundDeviceErrorNone && rates) {
            for (i = 0; i < count; i++) {
                if (rates[i] == 22050) supports22 = true;
                if (rates[i] == 44100) supports44 = true;
            }
        }
    }
    if (error != NX_SoundDeviceErrorNone) {
        SoundError("sampling rate query", error);
        return 0;
    }
    if (!supports22 && !supports44) {
        Com_Printf("SoundKit: output supports neither 22050 nor 44100 Hz\n");
        return 0;
    }
    rate = s_khz->value == 44 ? 44100 : 22050;
    if (rate == 22050 && !supports22) rate = 44100;
    if (rate == 44100 && !supports44) rate = 22050;
    /* The quality/compatibility menu requests 11 or 22 kHz on every restart.
     * Keep the cvar and mixer at a rate this output device actually accepts. */
    if (s_khz->value != (rate == 44100 ? 44 : 22)) {
        Com_Printf("SoundKit: using %d Hz for s_khz %s\n", rate, s_khz->string);
        Cvar_SetValue("s_khz", rate == 44100 ? 44 : 22);
    }
    return rate;
}

static void SoundInfo(void)
{
    if (!sound_ready) {
        Com_Printf("SoundKit: inactive\n");
        return;
    }
    Com_Printf("SoundKit: %d Hz, stereo Linear16, processed=%u submitted=%u "
        "queued=%u bytes (%.1f ms), underruns=%u\n", dma.speed, processed_bytes, submitted_bytes,
        submitted_bytes - processed_bytes,
        (submitted_bytes - processed_bytes) * 250.0 / dma.speed, underruns);
}

qboolean SNDDMA_Init(void)
{
    id <NXSoundParameters> parameters;
    NXSoundDeviceError error;
    int rate;

    if (sound_ready)
        return true;
    [NXSoundDevice setTimeout:1000];
    [NXSoundDevice setUseSeparateThread:NO];
    if (!sound_device)
        sound_device = [[NXSoundOut alloc] init];
    if (!sound_device) {
        Com_Printf("SoundKit: no output device available\n");
        return false;
    }
    rate = SoundRate();
    if (!rate)
        return false;
    if (!sound_stream) {
        parameters = [[NXSoundParameters alloc] init];
        sound_stream = [[NXPlayStream alloc] initOnDevice:sound_device withParameters:parameters];
        [(id)parameters release];
    }
    if (!sound_stream) {
        Com_Printf("SoundKit: cannot create playback stream\n");
        SNDDMA_Shutdown();
        return false;
    }
    parameters = [sound_stream parameters];
    [parameters setParameter:NX_SoundStreamDataEncoding
                      toInt:NX_SoundStreamDataEncoding_Linear16];
    [parameters setParameter:NX_SoundStreamSamplingRate toFloat:rate];
    [parameters setParameter:NX_SoundStreamChannelCount toInt:2];
    if (!sound_delegate)
        sound_delegate = [[QuakeSoundDelegate alloc] init];
    [sound_stream setDelegate:sound_delegate];
    error = [sound_stream activate];
    if (error != NX_SoundDeviceErrorNone) {
        SoundError("stream activation", error);
        SNDDMA_Shutdown();
        return false;
    }
    /* Queue the initial batch while paused. Starting on the first small
     * submission can distort playback even when later refills stay ahead. */
    if (!SoundPause())
        return false;
    dma.channels = 2;
    dma.samplebits = 16;
    dma.speed = rate;
    dma.samples = SOUND_FRAMES * 2;
    dma.submission_chunk = BLOCK_FRAMES;
    dma.samplepos = 0;
    dma.buffer = calloc(dma.samples, 2);
    if (!dma.buffer) {
        Com_Printf("SoundKit: cannot allocate mixer buffer\n");
        SNDDMA_Shutdown();
        return false;
    }
    block_stride = ((BLOCK_BYTES + vm_page_size - 1) / vm_page_size) * vm_page_size;
    block_memory_size = block_stride * SOUND_BLOCKS;
    if (vm_allocate(task_self(), &block_memory, block_memory_size, TRUE) != KERN_SUCCESS) {
        block_memory = 0;
        Com_Printf("SoundKit: cannot allocate playback buffers\n");
        SNDDMA_Shutdown();
        return false;
    }
    memset(blocks, 0, sizeof(blocks));
    processed_bytes = submitted_bytes = 0;
    underruns = 0;
    next_frame = next_block = 0;
    next_valid = painting = false;
    sound_ready = true;
    Cmd_AddCommand("snd_info", SoundInfo);
    info_registered = true;
    Com_Printf("SoundKit: %d Hz, 16-bit stereo streaming\n", rate);
    return true;
}

int SNDDMA_GetDMAPos(void)
{
    if (!sound_ready)
        return dma.samplepos;
    painting = true;
    dma.samplepos = (processed_bytes / 2) & (dma.samples - 1);
    return dma.samplepos;
}

void SNDDMA_Shutdown(void)
{
    sound_ready = false;
    stream_paused = false;
    if (sound_stream) {
        [sound_stream setDelegate:nil];
        [sound_stream deactivate];
    }
    /* SoundKit can dispatch pending replies after deactivate. Keep one stream
     * and its device/delegate for the process lifetime, reactivating it on
     * snd_restart. Unique buffer tags reject replies from earlier playback. */
    if (dma.buffer) {
        free(dma.buffer);
        dma.buffer = NULL;
    }
    if (block_memory) {
        vm_deallocate(task_self(), block_memory, block_memory_size);
        block_memory = 0;
    }
    memset(blocks, 0, sizeof(blocks));
    next_valid = painting = false;
    if (info_registered) {
        Cmd_RemoveCommand("snd_info");
        info_registered = false;
    }
}

void SNDDMA_BeginPainting(void)
{
    if (!sound_ready && dma.buffer)
        SNDDMA_Shutdown();
    painting = false;
}

void SNDDMA_Submit(void)
{
    NXSoundDeviceError error;
    int frames, i, source;
    unsigned short sample;
    short *mixed;
    byte *output;

    if (!sound_ready)
        return;
    /* S_ClearBuffer submits without querying the DMA position. Discard our
     * queued copies as well as the software ring on stopsound/map loading. */
    if (!painting) {
        if (submitted_bytes != processed_bytes) {
            [sound_stream abort:nil];
            error = [sound_stream lastError];
            if (error != NX_SoundDeviceErrorNone) {
                SoundError("stream abort", error);
                SNDDMA_Shutdown();
                return;
            }
        }
        if (!SoundPause())
            return;
        submitted_bytes = processed_bytes;
        memset(blocks, 0, sizeof(blocks));
        next_block = 0;
        next_valid = false;
        return;
    }
    painting = false;
    /* Refill a drained stream using the same startup sequence. */
    if (!stream_paused && submitted_bytes == processed_bytes && !SoundPause())
        return;
    if (!next_valid || next_frame < soundtime || next_frame > paintedtime) {
        next_frame = soundtime;
        next_valid = true;
    }
    mixed = (short *)dma.buffer;
    while (next_frame < paintedtime && !blocks[next_block].busy) {
        frames = paintedtime - next_frame;
        if (frames > BLOCK_FRAMES)
            frames = BLOCK_FRAMES;
        output = (byte *)(block_memory + next_block * block_stride);
        /* SoundKit Linear16 is big-endian; the Intel mixer ring is native.
         * Keep each submitted copy untouched until its completion callback. */
        for (i = 0; i < frames * 2; i++) {
            source = ((unsigned)next_frame * 2 + i) & (dma.samples - 1);
            sample = (unsigned short)mixed[source];
            output[i * 2] = sample >> 8;
            output[i * 2 + 1] = sample & 255;
        }
        blocks[next_block].tag = next_tag++ & 0x7fffffff;
        error = [sound_stream playBuffer:output size:frames * 4 tag:blocks[next_block].tag];
        if (error != NX_SoundDeviceErrorNone) {
            SoundError("buffer submission", error);
            SNDDMA_Shutdown();
            return;
        }
        submitted_bytes += frames * 4;
        blocks[next_block].bytes = frames * 4;
        blocks[next_block].busy = true;
        next_frame += frames;
        next_block = (next_block + 1) % SOUND_BLOCKS;
    }
    if (stream_paused && submitted_bytes != processed_bytes) {
        error = [sound_stream resumeAtTime:NX_SOUNDSTREAM_TIME_NULL];
        if (error != NX_SoundDeviceErrorNone) {
            SoundError("stream resume", error);
            SNDDMA_Shutdown();
            return;
        }
        stream_paused = false;
    }
}
