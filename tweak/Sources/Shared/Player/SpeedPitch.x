// Speed and Pitch (SpeedPitchMenu.x draws them), both done on Spotify's audio, under either look, and the
// record of Spotify's outputs that every processor of its sound follows (SpeedPitch.h).
//
// Spotify's player takes a speed only for podcasts: for songs its restrictions refuse it (device test,
// 2026-09-18: the slider read "Unavailable here"), its own music speed being a per track setting kept on
// playlist items. So speed, like pitch, is done to the sound, by SGTimePitch between Spotify's mixer and
// its speaker unit.
//
// Spotify's audio (AudioUnitDriver2 in the binary) is a chain of units it wires with MakeConnection:
// converter (fed by its decoder through a render callback), EQ, mixer, RemoteIO. Its import of
// AudioUnitSetProperty is rebound (Core/SGRebind.h), and the call connecting a mixer to a RemoteIO unit's
// input is answered by a render callback of this file's instead, which pulls the mixer itself. At normal
// speed and pitch the callback passes the mixer's sound straight through. Otherwise it renders the time and
// pitch unit, which pulls the mixer for rate times the frames it hands back, so Spotify's decoder is drained
// that much faster: the song plays faster or slower, at its own pitch unless Pitch moves it. Switching the
// unit in or out skips or repeats its 93 ms, so it stays in for a moment after both return to normal, and a
// finger dragging across normal does not switch it back and forth.
//
// Spotify keeps a chain per sample rate: a local file at another rate gets a second one, and both can be
// alive and running at once. So every RemoteIO unit has its own record (Output): the mixer and bus feeding
// it, that mixer's largest slice, a sample time of its own, and its two formats. Each unit's callback pulls
// only its own mixer; one pulling another's would drain it twice as fast, and the song would speed up. The
// processors (this file's unit, Sing's stage, the audio effects, Music Haptics) are on one output only, the
// music's: the one Spotify started or connected last, since a new chain is started for the song about to
// play. A unit Spotify never connected (one it feeds with a callback of its own, such as voice search) gets
// them only when no connected one runs. And an output that has had no sound for a second gives them up to
// a connected one that has: a chain left running and fed again without a new start (going back to a
// streamed song after a local file, or the end of a crossfade) is still found. AudioOutputUnitStop and
// AudioComponentInstanceDispose are rebound too: a stopped unit gives the processors up, and a disposed one
// is forgotten, after its render in progress is over, so nothing ever pulls a disposed mixer.
//
// The callback stands in for Spotify's connection only when it can: Spotify's side of the unit float, a
// buffer per channel, 32-bit, one or two channels, and the mixer's output the same rate, layout and
// channels. Otherwise Spotify's own connection is put back and its sound passes untouched (a mixer at
// another rate than the unit would play fast or slow through the callback, where Spotify's own connection
// refuses it). This is checked when Spotify connects, starts and changes a format, and the callback takes
// over again once the formats agree.
//
// Spotify's clock keeps running at its own speed between the player's reports: -[SPTPlayerState position]
// is positionAsOfTimestamp minus timeIntervalSinceNow times [self playbackSpeed] (disassembly,
// 0x1057735ec), so playbackSpeed is hooked to include this speed, and the scrubber, the lyrics and the lock
// screen move with the sound. That bets the player's reported positions follow what the decoder handed
// over, which is what it counts. The player does not report a change of this speed, so a state stamped
// before it would run all its time at the new speed and jump; -position takes back the difference for the
// time each earlier speed played (speedCorrection).
//
// When the music's output was never connected, pitch falls back to the way it first shipped: a render notify
// on the RemoteIO unit runs each finished buffer through a unit working in place; speed is then unavailable.
// Those buffers are in the unit's output format, the hardware's, not the one Spotify hands the unit
// (harness/audio-effects/sim), so the fallback's unit is made for that one.
//
// Speed and pitch last until Spotify quits.
//
// The music's render notify also scales each finished buffer by the gain SGPlayerSetGain asks for (the sleep
// timer's fade), in the chain or not.
//
// Threading: the render callbacks and the notify run on each unit's render thread and touch only atomics,
// their own output's record and the units. Spotify connects, starts, stops and disposes on its audio thread;
// the record changes under sg_outputsLock, there and on sg_outputsQueue (format changes, the silence check).
// A change waits for a render in progress to end; a render never waits. Everything else is main thread.
#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <pthread.h>
#import <stdatomic.h>
#import "Core/SGCore.h"
#import "Core/SGRebind.h"
#import "Headers/SPTPlayer.h"
#import "SpeedPitch.h"
#import "SGTimePitch.h"

// The unit stays in this long after speed and pitch both came back to normal.
static const double kOffAfter = 1.5;
// An output silent this long gives the processors up to a connected one that is not; one started or connected
// this recently counts as having sound.
static const double kSilentFor = 1;
// How often the outputs are checked for that while two or more run.
static const double kCheckEvery = 0.5;

enum { kMaxOutputs = 8, kMaxWatchers = 4 };

#pragma mark - shared between the threads

static float sg_speed = 1, sg_semitones;     // main thread
static atomic_uint sg_speedBits;             // sg_speed for SPTPlayerState, read on any thread

typedef struct {
    atomic_uint_fast64_t rateBits;
    atomic_uint flags, channels, bytes;
} Format;

// A RemoteIO unit of Spotify's. A slot whose unit is NULL is free; slots are used again, never freed, since a
// render thread may hold one.
typedef struct {
    _Atomic(AudioUnit) unit;
    // What Spotify connected to it, NULL when nothing is; `taken` while this file's callback stands in for that
    // connection, pulling it in chunks no larger than its own largest slice.
    _Atomic(AudioUnit) source;
    UInt32 sourceBus;
    atomic_bool taken;
    atomic_uint chunk;
    Float64 sourceTime;                      // its render thread only
    // Spotify's side (input scope, element 0), which the callback fills, and the hardware's (output scope),
    // which render notifies get.
    Format client, hardware;
    atomic_bool running, busy;
    atomic_uint_fast64_t loudAt;             // host time of its last rendered buffer with sound
    // Under sg_outputsLock: when Spotify last started or connected it, as an order and as a host time,
    // and whether its notify and listener are on.
    uint64_t order, eventAt;
    BOOL listened;
} Output;

static Output sg_outputs[kMaxOutputs];
static _Atomic(Output *) sg_music;           // the output carrying the processors
static pthread_mutex_t sg_outputsLock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;
static dispatch_queue_t sg_outputsQueue;
static SGPlayerOutputWatcher sg_watchers[kMaxWatchers];
static BOOL sg_reachable;                    // Spotify's AudioOutputUnitStart could be rebound

// The unit in use and whether the render thread runs it: in the music's chain (pull), else in place (pitch only).
static _Atomic(SGTimePitch *) sg_pull, sg_inPlace;
static atomic_bool sg_engaged;
static pthread_mutex_t sg_buildLock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic(SGPlayerStage) sg_stage;

static double sg_secondsPerTick;
static OSStatus (*sg_setProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);

static Output *music(void) {
    return atomic_load(&sg_music);
}

// Whether the music's output is fed through this file's callback.
static BOOL tapped(void) {
    Output *output = music();
    return output && atomic_load(&output->taken);
}

static double rateOf(Format *format) {
    uint64_t bits = atomic_load_explicit(&format->rateBits, memory_order_relaxed);
    double rate;
    memcpy(&rate, &bits, sizeof rate);
    return rate;
}

static float loadFloat(atomic_uint *slot) {
    uint32_t bits = atomic_load(slot);
    float value;
    memcpy(&value, &bits, sizeof value);
    return value;
}

static void storeFloat(atomic_uint *slot, float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof bits);
    atomic_store(slot, bits);
}

static double seconds(uint64_t ticks) {
    return ticks * sg_secondsPerTick;
}

#pragma mark - the render thread: the chain

static void silence(AudioBufferList *data) {
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) if (data->mBuffers[b].mData) memset(data->mBuffers[b].mData, 0, data->mBuffers[b].mDataByteSize);
}

// The output's mixer's next `frames` frames into `data`, in chunks of at most its largest slice, each with a
// sample time of the output's own, so Spotify's units never see a time twice (an AU renders a time it has
// seen from cache). With `sounding`, it stops at the first chunk marked silent (SGPlayerPull).
static OSStatus pullSource(Output *output, AudioUnit source, const AudioTimeStamp *outputTime, UInt32 frames, AudioBufferList *data, UInt32 *sounding) {
    enum { kMaxBuffers = 8 };
    UInt32 chunk = atomic_load_explicit(&output->chunk, memory_order_relaxed);
    if (data->mNumberBuffers > kMaxBuffers) chunk = frames;
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) if (!data->mBuffers[b].mData) chunk = frames;
    UInt32 bytesPerFrame[kMaxBuffers];
    for (UInt32 b = 0; b < data->mNumberBuffers && b < kMaxBuffers; b++) bytesPerFrame[b] = data->mBuffers[b].mDataByteSize / frames;
    if (sounding) *sounding = frames;

    for (UInt32 done = 0; done < frames;) {
        UInt32 count = MIN(chunk, frames - done);
        struct { AudioBufferList list; AudioBuffer more[kMaxBuffers - 1]; } part;
        AudioBufferList *target = data;
        if (count != frames) {
            part.list.mNumberBuffers = data->mNumberBuffers;
            for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
                part.list.mBuffers[b] = (AudioBuffer){data->mBuffers[b].mNumberChannels, count * bytesPerFrame[b],
                                                      (char *)data->mBuffers[b].mData + done * bytesPerFrame[b]};
            }
            target = &part.list;
        }
        AudioTimeStamp time = outputTime ? *outputTime : (AudioTimeStamp){0};
        time.mSampleTime = output->sourceTime;
        time.mFlags |= kAudioTimeStampSampleTimeValid;
        AudioUnitRenderActionFlags flags = 0;
        OSStatus status = AudioUnitRender(source, &flags, &time, output->sourceBus, count, target);
        output->sourceTime += count;
        if (status != noErr) return status;
        // Asked to stop at silence: Spotify has none of its sound from here on yet, so the rest is not rendered.
        if ((flags & kAudioUnitRenderAction_OutputIsSilence) && sounding) {
            *sounding = done;
            for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
                UInt32 per = data->mBuffers[b].mDataByteSize / frames;
                if (data->mBuffers[b].mData) memset((char *)data->mBuffers[b].mData + done * per, 0, (frames - done) * per);
            }
            return noErr;
        }
        // A buffer marked silent may still hold what was in it before; nothing after this reads the mark.
        if (flags & kAudioUnitRenderAction_OutputIsSilence) silence(target);
        done += count;
    }
    return noErr;
}

void SGPlayerSetStage(SGPlayerStage stage) {
    atomic_store(&sg_stage, stage);
}

typedef struct {
    Output *output;
    AudioUnit source;
    const AudioTimeStamp *time;
} MixerPull;

static OSStatus pullMixer(void *context, UInt32 frames, AudioBufferList *data, UInt32 *sounding) {
    MixerPull *mixer = context;
    return pullSource(mixer->output, mixer->source, mixer->time, frames, data, sounding);
}

// The music's mixer's sound, through the stage when one is set.
static OSStatus pullChain(Output *output, AudioUnit source, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *data) {
    SGPlayerStage stage = atomic_load_explicit(&sg_stage, memory_order_acquire);
    if (!stage) return pullSource(output, source, time, frames, data, NULL);
    MixerPull mixer = {output, source, time};
    return stage(frames, data, pullMixer, &mixer);
}

// Whether the time and pitch unit pulled the mixer during the render under way. The music's render thread only.
static bool sg_unitPulled;

// The time and pitch unit's input. It renders only on the music's output, and a change of music takes the
// unit out first (disengage), so the music here is the output rendering it.
static OSStatus pullForUnit(void *context, UInt32 frames, AudioBufferList *data) {
    sg_unitPulled = true;
    Output *output = music();
    AudioUnit source = output ? atomic_load(&output->source) : NULL;
    if (!source) {
        silence(data);
        return noErr;
    }
    return pullChain(output, source, NULL, frames, data);
}

static BOOL fitsUnit(const AudioBufferList *data, UInt32 frames, SGTimePitch *unit) {
    if (data->mNumberBuffers != SGTimePitchChannels(unit) || frames > kSGTimePitchMaxFrames) return NO;
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
        if (!data->mBuffers[b].mData || data->mBuffers[b].mDataByteSize < frames * sizeof(float)) return NO;
    }
    return YES;
}

// A RemoteIO unit's input, in place of Spotify's connection from its mixer. `refCon` is its Output.
static OSStatus feed(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                     UInt32 frames, AudioBufferList *data) {
    Output *output = refCon;
    atomic_store(&output->busy, true);
    AudioUnit source = atomic_load(&output->source);
    OSStatus status = noErr;
    if (!source) {
        silence(data);
        *flags |= kAudioUnitRenderAction_OutputIsSilence;
    } else if (output != music()) {
        // Another chain plays as Spotify made it.
        status = pullSource(output, source, timestamp, frames, data, NULL);
    } else {
        SGTimePitch *unit = atomic_load(&sg_pull);
        // A unit made for another rate passes the sound as it is, until the main thread makes one for the new rate.
        BOOL tried = atomic_load(&sg_engaged) && unit && fitsUnit(data, frames, unit) && SGTimePitchSampleRate(unit) == rateOf(&output->client);
        sg_unitPulled = false;
        status = tried ? SGTimePitchRender(unit, frames, data) : -1;
        if (status != noErr && tried && sg_unitPulled) {
            // The failed render took the mixer's sound already: a second pull would skip a buffer of the song,
            // so this one is silent instead.
            silence(data);
            *flags |= kAudioUnitRenderAction_OutputIsSilence;
            status = noErr;
        } else if (status != noErr) {
            status = pullChain(output, source, timestamp, frames, data);
        }
    }
    atomic_store(&output->busy, false);
    return status;
}

#pragma mark - the render thread: in place, the fallback

static float sg_scratch[kSGTimePitchMaxChannels][kSGTimePitchMaxFrames];

static inline float readSample(const void *data, UInt32 index, UInt32 bytes, BOOL isFloat, UInt32 fraction) {
    if (bytes == 4) {
        if (isFloat) return ((const float *)data)[index];
        int32_t value = ((const int32_t *)data)[index];
        return fraction ? (float)((double)value / (double)(1u << fraction)) : (float)(value / 2147483648.0);
    }
    return ((const int16_t *)data)[index] / 32768.0f;
}

static inline void writeSample(void *data, UInt32 index, float value, UInt32 bytes, BOOL isFloat, UInt32 fraction) {
    if (bytes == 4 && isFloat) {
        ((float *)data)[index] = value;
        return;
    }
    value = fmaxf(-1, fminf(value, 1));
    if (bytes == 4) {
        double scale = fraction ? (double)(1u << fraction) : 2147483647.0;
        ((int32_t *)data)[index] = (int32_t)(value * scale);
    } else {
        ((int16_t *)data)[index] = (int16_t)(value * 32767);
    }
}

static void shiftInPlace(SGTimePitch *unit, Format *hardware, AudioUnitRenderActionFlags *flags, UInt32 frames, AudioBufferList *data) {
    UInt32 formatFlags = atomic_load_explicit(&hardware->flags, memory_order_relaxed);
    UInt32 bytes = atomic_load_explicit(&hardware->bytes, memory_order_relaxed);
    UInt32 channels = SGTimePitchChannels(unit);
    BOOL isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL split = (formatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 fraction = (formatFlags & kLinearPCMFormatFlagsSampleFractionMask) >> kLinearPCMFormatFlagsSampleFractionShift;
    if (frames > kSGTimePitchMaxFrames || (bytes != 2 && bytes != 4)) return;
    if (split ? data->mNumberBuffers != channels : data->mNumberBuffers != 1 || data->mBuffers[0].mNumberChannels != channels) return;
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
        if (!data->mBuffers[b].mData || data->mBuffers[b].mDataByteSize < frames * bytes * (split ? 1 : channels)) return;
    }
    // Silence still goes through, so the sound the unit holds plays out rather than coming back later.
    BOOL silent = (*flags & kAudioUnitRenderAction_OutputIsSilence) != 0;

    float *lanes[kSGTimePitchMaxChannels];
    BOOL direct = split && isFloat && bytes == 4 && !silent;
    for (UInt32 c = 0; c < channels; c++) {
        if (direct) {
            lanes[c] = data->mBuffers[c].mData;
            continue;
        }
        lanes[c] = sg_scratch[c];
        const void *source = data->mBuffers[split ? c : 0].mData;
        for (UInt32 i = 0; i < frames; i++) {
            lanes[c][i] = silent ? 0 : readSample(source, split ? i : i * channels + c, bytes, isFloat, fraction);
        }
    }
    if (!SGTimePitchProcess(unit, lanes, frames) || direct) return;
    for (UInt32 c = 0; c < channels; c++) {
        void *target = data->mBuffers[split ? c : 0].mData;
        for (UInt32 i = 0; i < frames; i++) writeSample(target, split ? i : i * channels + c, lanes[c][i], bytes, isFloat, fraction);
    }
    *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
}

// Whether a buffer in `format` holds sound: float over -80 dB, so a mixer's noise floor is not taken for
// music, and in any other format anything but zeros.
static BOOL hasSound(Format *format, AudioUnitRenderActionFlags flags, const AudioBufferList *data) {
    if (flags & kAudioUnitRenderAction_OutputIsSilence) return NO;
    BOOL floats = (atomic_load_explicit(&format->flags, memory_order_relaxed) & kAudioFormatFlagIsFloat)
                  && atomic_load_explicit(&format->bytes, memory_order_relaxed) == 4;
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
        const uint32_t *words = data->mBuffers[b].mData;
        UInt32 count = words ? data->mBuffers[b].mDataByteSize / sizeof *words : 0;
        for (UInt32 i = 0; i < count; i++) {
            if (floats ? fabsf(((const float *)words)[i]) > 1e-4f : words[i] != 0) return YES;
        }
    }
    return NO;
}

#pragma mark - the render thread: the gain

// The gain asked for (main thread writes, render thread reads) and the one the sound is at (the music's render
// thread only). The sound moves toward the one asked for by at most the whole way in kGainSlew seconds, so a
// fade that starts late, a timer canceled halfway or more time added never steps.
static const double kGainSlew = 0.5;
static atomic_uint sg_gainBits;
static float sg_gainNow = 1;

// Scales a finished buffer, in the hardware's format, ramping each frame from where the last buffer left off.
// Integers scale as they are, so a fixed point format needs no conversion.
static void applyGain(Format *hardware, AudioUnitRenderActionFlags *flags, UInt32 frames, AudioBufferList *data) {
    float target = loadFloat(&sg_gainBits);
    if (target == 1 && sg_gainNow == 1) return;
    UInt32 bytes = atomic_load_explicit(&hardware->bytes, memory_order_relaxed);
    double rate = rateOf(hardware);
    if ((bytes != 2 && bytes != 4) || rate <= 0) return;
    float from = sg_gainNow, most = (float)(frames / (kGainSlew * rate));
    float to = from + fmaxf(-most, fminf(target - from, most));
    sg_gainNow = to;
    if (*flags & kAudioUnitRenderAction_OutputIsSilence) return;
    BOOL isFloat = (atomic_load_explicit(&hardware->flags, memory_order_relaxed) & kAudioFormatFlagIsFloat) != 0;
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
        AudioBuffer *buffer = &data->mBuffers[b];
        UInt32 channels = MAX(buffer->mNumberChannels, 1u), samples = buffer->mDataByteSize / bytes;
        if (!buffer->mData || samples < frames * channels) continue;
        for (UInt32 i = 0; i < frames * channels; i++) {
            float gain = from + (to - from) * (float)(i / channels) / (float)frames;
            if (bytes == 2) ((int16_t *)buffer->mData)[i] = (int16_t)(((int16_t *)buffer->mData)[i] * gain);
            else if (isFloat) ((float *)buffer->mData)[i] *= gain;
            else ((int32_t *)buffer->mData)[i] = (int32_t)(((int32_t *)buffer->mData)[i] * (double)gain);
        }
    }
}

// On every started output, `refCon` its Output: notes when it has sound, and shifts the pitch on the music's
// when it is not fed by the callback.
static OSStatus rendered(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                         UInt32 frames, AudioBufferList *data) {
    if (!(*flags & kAudioUnitRenderAction_PostRender) || bus != 0 || !data || !data->mNumberBuffers || !frames) return noErr;
    Output *output = refCon;
    if (hasSound(&output->hardware, *flags, data)) atomic_store_explicit(&output->loudAt, mach_absolute_time(), memory_order_relaxed);
    if (output != music()) return noErr;
    applyGain(&output->hardware, flags, frames, data);
    if (atomic_load(&output->taken) || !atomic_load(&sg_engaged)) return noErr;
    atomic_store(&output->busy, true);
    SGTimePitch *unit = atomic_load(&sg_inPlace);
    if (atomic_load(&sg_engaged) && output == music() && unit && SGTimePitchSampleRate(unit) == rateOf(&output->hardware)) {
        shiftInPlace(unit, &output->hardware, flags, frames, data);
    }
    atomic_store(&output->busy, false);
    return noErr;
}

#pragma mark - the outputs (sg_outputsLock)

static BOOL isRemoteIO(AudioUnit unit) {
    AudioComponentDescription description = {0};
    if (!unit || AudioComponentGetDescription(AudioComponentInstanceGetComponent(unit), &description) != noErr) return NO;
    return description.componentType == kAudioUnitType_Output && description.componentSubType == kAudioUnitSubType_RemoteIO;
}

static Output *outputOf(AudioUnit unit) {
    for (int i = 0; unit && i < kMaxOutputs; i++) if (atomic_load(&sg_outputs[i].unit) == unit) return &sg_outputs[i];
    return NULL;
}

static Output *outputFor(AudioUnit unit) {
    Output *output = outputOf(unit);
    for (int i = 0; !output && i < kMaxOutputs; i++) {
        if (atomic_load(&sg_outputs[i].unit)) continue;
        output = &sg_outputs[i];
        atomic_store(&output->source, NULL);
        atomic_store(&output->taken, false);
        atomic_store(&output->running, false);
        atomic_store(&output->chunk, 1024);
        atomic_store(&output->loudAt, 0);
        output->sourceTime = 0;
        output->order = output->eventAt = 0;
        output->listened = NO;
        atomic_store(&output->unit, unit);
    }
    if (!output) {
        static int logged;
        if (logged++ < 3) SGLog(@"audio: more than %d outputs at once, %p is left as Spotify made it", kMaxOutputs, unit);
    }
    return output;
}

// Waits for the output's render in progress, if any, to end.
static void waitFor(Output *output) {
    for (int i = 0; i < 400 && atomic_load(&output->busy); i++) usleep(250);
}

// Stops the render threads using the unit, and returns once none is.
static void disengage(void) {
    atomic_store(&sg_engaged, false);
    for (int i = 0; i < kMaxOutputs; i++) waitFor(&sg_outputs[i]);
}

static void readScope(AudioUnit unit, AudioUnitScope scope, Format *into, AudioStreamBasicDescription *format) {
    UInt32 size = sizeof *format;
    OSStatus status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 0, format, &size);
    if (status != noErr || format->mFormatID != kAudioFormatLinearPCM || format->mSampleRate <= 0) {
        *format = (AudioStreamBasicDescription){0};
    }
    uint64_t bits;
    memcpy(&bits, &format->mSampleRate, sizeof bits);
    atomic_store(&into->rateBits, bits);
    atomic_store(&into->flags, format->mFormatFlags);
    atomic_store(&into->channels, format->mChannelsPerFrame);
    atomic_store(&into->bytes, format->mBitsPerChannel / 8);
}

static NSString *formatText(const AudioStreamBasicDescription *format) {
    if (format->mFormatID != kAudioFormatLinearPCM) return @"not linear PCM";
    return [NSString stringWithFormat:@"%.0f Hz, %u ch, %u-bit %@%@", format->mSampleRate, (unsigned)format->mChannelsPerFrame,
            (unsigned)format->mBitsPerChannel, (format->mFormatFlags & kAudioFormatFlagIsFloat) ? @"float" : @"integer",
            (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? @" split" : @" interleaved"];
}

// Why the callback cannot stand in for the connection to the client format `client`, nil when it can.
static NSString *refusal(Output *output, const AudioStreamBasicDescription *client) {
    BOOL canonical = client->mFormatID == kAudioFormatLinearPCM && (client->mFormatFlags & kAudioFormatFlagIsFloat)
                     && (client->mFormatFlags & kAudioFormatFlagIsNonInterleaved) && client->mBitsPerChannel == 32
                     && client->mChannelsPerFrame >= 1 && client->mChannelsPerFrame <= kSGTimePitchMaxChannels;
    if (!canonical) return [NSString stringWithFormat:@"Spotify's side is %@, not float split 1 or 2 ch", formatText(client)];
    AudioStreamBasicDescription mixer = {0};
    UInt32 size = sizeof mixer;
    AudioUnit source = atomic_load(&output->source);
    if (AudioUnitGetProperty(source, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, output->sourceBus, &mixer, &size) != noErr) return nil;
    UInt32 layout = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved;
    if (mixer.mSampleRate != client->mSampleRate || (mixer.mFormatFlags & layout) != (client->mFormatFlags & layout)
        || mixer.mChannelsPerFrame != client->mChannelsPerFrame || mixer.mBitsPerChannel != client->mBitsPerChannel) {
        return [NSString stringWithFormat:@"its mixer gives %@ for %@", formatText(&mixer), formatText(client)];
    }
    return nil;
}

// Reads both formats and the mixer's slice, and puts in the callback or Spotify's own connection, whichever
// the formats allow. Answers why Spotify's connection is kept, nil when the callback feeds the output.
static NSString *settle(Output *output, AudioStreamBasicDescription *client, AudioStreamBasicDescription *hardware) {
    AudioUnit unit = atomic_load(&output->unit);
    readScope(unit, kAudioUnitScope_Input, &output->client, client);
    readScope(unit, kAudioUnitScope_Output, &output->hardware, hardware);
    AudioUnit source = atomic_load(&output->source);
    if (!source) return @"not connected";
    UInt32 slice = 0, size = sizeof slice;
    if (AudioUnitGetProperty(source, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &slice, &size) == noErr && slice >= 256) {
        atomic_store(&output->chunk, slice);
    }
    NSString *why = refusal(output, client);
    BOOL take = !why;
    if (take == atomic_load(&output->taken)) return why;
    OSStatus status;
    if (take) {
        AURenderCallbackStruct callback = {feed, output};
        status = sg_setProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof callback);
    } else {
        // Its sound passes as Spotify made it; the callback's render in progress, if any, ends first.
        AudioUnitConnection connection = {source, output->sourceBus, 0};
        status = sg_setProperty(unit, kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, 0, &connection, sizeof connection);
        waitFor(output);
    }
    if (status == noErr) atomic_store(&output->taken, take);
    SGLog(@"audio: output %p %@ (status %d)%@", unit, take ? @"fed through the mod's callback" : @"given Spotify's own connection back",
          (int)status, why ? [@": " stringByAppendingString:why] : @"");
    return atomic_load(&output->taken) ? nil : why ?: @"the callback could not be set";
}

static void markEvent(Output *output) {
    static uint64_t order;
    output->order = ++order;
    output->eventAt = mach_absolute_time();
}

static NSString *describe(Output *output) {
    if (!output) return @"none";
    return [NSString stringWithFormat:@"%p (%.0f Hz)", atomic_load(&output->unit), rateOf(&output->client)];
}

static void tellWatchers(void) {
    Output *output = music();
    AudioUnit unit = output ? atomic_load(&output->unit) : NULL;
    for (int i = 0; i < kMaxWatchers && sg_watchers[i]; i++) sg_watchers[i](unit);
}

static void applyToFormat(void);

// The output that should carry the processors, Spotify's newest of the best kind: running and connected
// with sound in the last second, then running and connected, then running and fed by Spotify itself, then
// connected but not started, so speed can be chosen before Spotify starts it.
static Output *choose(void) {
    uint64_t now = mach_absolute_time();
    Output *best = NULL;
    int bestRank = -1;
    for (int i = 0; i < kMaxOutputs; i++) {
        Output *output = &sg_outputs[i];
        if (!atomic_load(&output->unit)) continue;
        BOOL connected = atomic_load(&output->source) != NULL, running = atomic_load(&output->running);
        if (!running && !connected) continue;
        BOOL sounds = seconds(now - MAX(atomic_load(&output->loudAt), output->eventAt)) < kSilentFor;
        int rank = running * 4 + connected * 2 + (running && connected && sounds);
        if (rank > bestRank || (rank == bestRank && output->order > best->order)) {
            best = output;
            bestRank = rank;
        }
    }
    return best;
}

// Hands the processors to the output that should have them; the watchers are told when they moved, or when
// `always` (a start of the music's output, a format change on it).
static void reselect(BOOL always, NSString *why) {
    Output *previous = music(), *next = choose();
    if (next != previous) {
        disengage();
        // The newest now, so it keeps the processors through a tie with the one it took them from.
        if (next) markEvent(next);
        atomic_store(&sg_music, next);
        SGLog(@"audio: the processors move from %@ to %@%@", describe(previous), describe(next), why ? [@", " stringByAppendingString:why] : @"");
    }
    if (next != previous || always) {
        tellWatchers();
        applyToFormat();
    }
}

static void checkSilence(void) {
    pthread_mutex_lock(&sg_outputsLock);
    int running = 0;
    for (int i = 0; i < kMaxOutputs; i++) running += atomic_load(&sg_outputs[i].unit) && atomic_load(&sg_outputs[i].running);
    if (running > 1) reselect(NO, [NSString stringWithFormat:@"its output silent for %.0f s while another has sound", kSilentFor]);
    pthread_mutex_unlock(&sg_outputsLock);
}

static void formatChanged(void *refCon, AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element) {
    if (property != kAudioUnitProperty_StreamFormat || element != 0) return;
    if (scope != kAudioUnitScope_Input && scope != kAudioUnitScope_Output) return;
    // Off the thread setting it: settling may set the unit's connection, which is not done from inside its own listener.
    Output *output = refCon;
    dispatch_async(sg_outputsQueue, ^{
        pthread_mutex_lock(&sg_outputsLock);
        if (atomic_load(&output->unit) == unit) {
            AudioStreamBasicDescription client, hardware;
            settle(output, &client, &hardware);
            SGLog(@"audio: output %p's format changed: Spotify's side %@, the hardware's %@", unit, formatText(&client), formatText(&hardware));
            reselect(output == music(), nil);
        }
        pthread_mutex_unlock(&sg_outputsLock);
    });
}

#pragma mark - Spotify's audio thread

// A format or slice Spotify sets on a mixer feeding an output: settled again, the output's own listener
// covering its side.
static void sourceChanged(AudioUnit unit) {
    pthread_mutex_lock(&sg_outputsLock);
    for (int i = 0; i < kMaxOutputs; i++) {
        Output *output = &sg_outputs[i];
        AudioUnit outputUnit = atomic_load(&output->unit);
        if (!outputUnit || atomic_load(&output->source) != unit) continue;
        dispatch_async(sg_outputsQueue, ^{
            pthread_mutex_lock(&sg_outputsLock);
            AudioStreamBasicDescription client, hardware;
            if (atomic_load(&output->unit) == outputUnit && atomic_load(&output->source) == unit) {
                settle(output, &client, &hardware);
                if (output == music()) applyToFormat();
            }
            pthread_mutex_unlock(&sg_outputsLock);
        });
    }
    pthread_mutex_unlock(&sg_outputsLock);
}

static OSStatus setProperty(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element,
                            const void *data, UInt32 size) {
    if (property != kAudioUnitProperty_MakeConnection || scope != kAudioUnitScope_Input || element != 0 || !data
        || size < sizeof(AudioUnitConnection) || !isRemoteIO(unit)) {
        OSStatus status = sg_setProperty(unit, property, scope, element, data, size);
        if (status == noErr && (property == kAudioUnitProperty_StreamFormat || property == kAudioUnitProperty_MaximumFramesPerSlice)) sourceChanged(unit);
        return status;
    }
    const AudioUnitConnection *connection = data;
    pthread_mutex_lock(&sg_outputsLock);
    Output *output = outputFor(unit);
    if (!output) {
        pthread_mutex_unlock(&sg_outputsLock);
        return sg_setProperty(unit, property, scope, element, data, size);
    }
    if (!connection->sourceAudioUnit) {
        BOOL wasTaken = atomic_exchange(&output->taken, false);
        atomic_store(&output->source, NULL);
        waitFor(output);
        if (wasTaken) {
            AURenderCallbackStruct none = {0};
            sg_setProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &none, sizeof none);
        }
        SGLog(@"audio: Spotify disconnected output %p", unit);
        OSStatus status = sg_setProperty(unit, property, scope, element, data, size);
        reselect(NO, @"its output disconnected");
        pthread_mutex_unlock(&sg_outputsLock);
        return status;
    }
    // A new mixer: the old one's render, if any, ends first, and the new one's time starts at 0.
    atomic_store(&output->taken, false);
    atomic_store(&output->source, NULL);
    waitFor(output);
    output->sourceBus = connection->sourceOutputNumber;
    output->sourceTime = 0;
    atomic_store(&output->source, connection->sourceAudioUnit);
    markEvent(output);
    AudioStreamBasicDescription client, hardware;
    // Spotify's connection is made too only when the callback cannot stand in for it.
    NSString *why = settle(output, &client, &hardware);
    OSStatus status = why ? sg_setProperty(unit, property, scope, element, data, size) : noErr;
    SGLog(@"audio: Spotify connects mixer %p (bus %u) to output %p, %@%@", connection->sourceAudioUnit, (unsigned)connection->sourceOutputNumber,
          unit, formatText(&client), why ? [@"; its own connection kept: " stringByAppendingString:why] : @"; fed through the mod's callback");
    reselect(NO, @"Spotify connected it last");
    pthread_mutex_unlock(&sg_outputsLock);
    return status;
}

static OSStatus (*sg_startOutput)(AudioUnit unit);

// The silence check, a couple of times a second from Spotify's first start; it returns at once unless two
// outputs run.
static void startChecking(void) {
    static dispatch_once_t once;
    static dispatch_source_t timer;   // kept, or it stops with its last reference
    dispatch_once(&once, ^{
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sg_outputsQueue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(kCheckEvery * NSEC_PER_SEC), NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(timer, ^{
            checkSilence();
        });
        dispatch_resume(timer);
    });
}

static OSStatus startOutput(AudioUnit unit) {
    if (!isRemoteIO(unit)) return sg_startOutput(unit);
    pthread_mutex_lock(&sg_outputsLock);
    Output *output = outputFor(unit);
    if (output) {
        startChecking();
        AudioStreamBasicDescription client, hardware;
        NSString *why = settle(output, &client, &hardware);
        markEvent(output);
        atomic_store(&output->running, true);
        if (!output->listened) {
            output->listened = YES;
            AudioUnitAddRenderNotify(unit, rendered, output);
            AudioUnitAddPropertyListener(unit, kAudioUnitProperty_StreamFormat, formatChanged, output);
        }
        // Every start of the music's output is told, so what holds sound from before the pause starts over.
        reselect(music() == output, @"Spotify started it last");
        AudioUnit source = atomic_load(&output->source);
        SGLog(@"audio: output %p started: Spotify's side %@, the hardware's %@, %@; the processors are on %@", unit, formatText(&client),
              formatText(&hardware), !source ? @"fed by Spotify itself" : why ? [NSString stringWithFormat:@"mixer %p through Spotify's connection (%@)", source, why]
              : [NSString stringWithFormat:@"mixer %p through the mod's callback", source], music() == output ? @"this one" : describe(music()));
    }
    pthread_mutex_unlock(&sg_outputsLock);
    return sg_startOutput(unit);
}

static OSStatus (*sg_stopOutput)(AudioUnit unit);

static OSStatus stopOutput(AudioUnit unit) {
    OSStatus status = sg_stopOutput(unit);
    pthread_mutex_lock(&sg_outputsLock);
    Output *output = outputOf(unit);
    if (output && atomic_exchange(&output->running, false)) {
        reselect(NO, @"its output stopped");
        SGLog(@"audio: output %p stopped (Spotify's side %.0f Hz); the processors are on %@", unit, rateOf(&output->client), describe(music()));
    }
    pthread_mutex_unlock(&sg_outputsLock);
    return status;
}

static OSStatus (*sg_dispose)(AudioComponentInstance unit);

// Every output fed by the unit loses it, and the unit's own output is forgotten, before it goes; renders in
// progress end first.
static OSStatus disposeUnit(AudioComponentInstance unit) {
    pthread_mutex_lock(&sg_outputsLock);
    BOOL changed = NO;
    for (int i = 0; i < kMaxOutputs; i++) {
        Output *output = &sg_outputs[i];
        AudioUnit outputUnit = atomic_load(&output->unit);
        if (!outputUnit) continue;
        if (outputUnit == unit) {
            if (output == music()) disengage();
            atomic_store(&output->running, false);
            atomic_store(&output->source, NULL);
            waitFor(output);
            atomic_store(&output->unit, NULL);
            SGLog(@"audio: output %p disposed (Spotify's side %.0f Hz)", unit, rateOf(&output->client));
            changed = YES;
        } else if (atomic_load(&output->source) == unit) {
            atomic_store(&output->source, NULL);
            waitFor(output);
            SGLog(@"audio: mixer %p disposed, output %p plays silence until Spotify connects another", unit, outputUnit);
            changed = YES;
        }
    }
    if (changed) reselect(NO, @"a unit disposed");
    // Under the lock, so its slot is not used again while its last render may still be running.
    OSStatus status = sg_dispose(unit);
    pthread_mutex_unlock(&sg_outputsLock);
    return status;
}

#pragma mark - engaging the unit

// The unit for the music's format and the way in use, made when there is none or the format changed. A
// replaced one is never freed: the render thread may still hold it, and a format change is rare.
static SGTimePitch *unitForFormat(void) {
    Output *output = music();
    if (!output) return NULL;
    BOOL pull = atomic_load(&output->taken);
    Format *format = pull ? &output->client : &output->hardware;
    double rate = rateOf(format);
    UInt32 channels = atomic_load(&format->channels);
    if (rate <= 0 || channels < 1 || channels > kSGTimePitchMaxChannels) return NULL;
    _Atomic(SGTimePitch *) *slot = pull ? &sg_pull : &sg_inPlace;
    pthread_mutex_lock(&sg_buildLock);
    SGTimePitch *unit = atomic_load(slot);
    if (!unit || SGTimePitchSampleRate(unit) != rate || SGTimePitchChannels(unit) != channels) {
        BOOL wasEngaged = atomic_load(&sg_engaged);
        disengage();
        unit = SGTimePitchCreate(rate, channels, pull ? pullForUnit : NULL, NULL);
        if (unit) {
            SGTimePitchSetFollows(unit, SGPlayerPitchFollowsSpeed());
            SGTimePitchSetRate(unit, pull ? sg_speed : 1);
            SGTimePitchSetSemitones(unit, sg_semitones);
            SGTimePitchReset(unit);
        }
        atomic_store(slot, unit);
        SGLog(@"redesign speed: %@ %@ for %.0f Hz, %u channels", unit ? @"a unit" : @"no unit", pull ? @"in the chain" : @"in place", rate, (unsigned)channels);
        if (unit && wasEngaged) atomic_store(&sg_engaged, true);
    }
    pthread_mutex_unlock(&sg_buildLock);
    return unit;
}

static void report(void) {
    SGTimePitch *unit = atomic_load(tapped() ? &sg_pull : &sg_inPlace);
    if (!unit) return;
    SGLog(@"redesign speed: %.2fx, %+.0f st, %u underruns, %u failures, largest pull %u, %.1f s of input", sg_speed, sg_semitones,
          SGTimePitchUnderruns(unit), SGTimePitchFailures(unit), SGTimePitchLargestPull(unit),
          SGTimePitchConsumed(unit) / SGTimePitchSampleRate(unit));
}

// Hands the render thread to the unit's other half, reset, when the speed, the pitch or Pitch follows speed
// now call for it. That costs the unit's delay once (93 ms going to the stretch), the same as putting it in,
// where rendering the other half as it was left would play what it held from last time.
static void switchIfAsked(SGTimePitch *unit) {
    if (!atomic_load(&sg_engaged) || !SGTimePitchSwitchPending(unit)) return;
    disengage();
    SGTimePitchReset(unit);
    atomic_store(&sg_engaged, true);
}

// Puts the unit in or takes it out for the current speed and pitch.
static void apply(void) {
    BOOL normal = sg_speed == 1 && sg_semitones == 0;
    static NSUInteger change;
    NSUInteger thisChange = ++change;
    if (normal) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kOffAfter * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (thisChange != change || sg_speed != 1 || sg_semitones != 0 || !atomic_load(&sg_engaged)) return;
            report();
            disengage();
        });
    }
    SGTimePitch *unit = unitForFormat();
    if (!unit) {
        static int logged;
        if (!normal && logged++ < 3) SGLog(@"redesign speed: Spotify's output has not started, or is in a format the unit does not take; nothing to change yet");
        return;
    }
    SGTimePitchSetRate(unit, tapped() ? sg_speed : 1);
    SGTimePitchSetSemitones(unit, sg_semitones);
    if (!normal && !atomic_load(&sg_engaged)) {
        disengage();
        SGTimePitchReset(unit);
        atomic_store(&sg_engaged, true);
    }
    switchIfAsked(unit);
}

// A speed or pitch chosen before the output started, or kept across a new format or another output, applies
// now: apply() makes the unit again when the rate or the channels changed, and puts it back in, reset, after
// a change of output took it out.
static void applyToFormat(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sg_speed != 1 || sg_semitones != 0) apply();
    });
}

#pragma mark - the calls

double SGPlayerSpeed(void) {
    return sg_speed;
}

BOOL SGPlayerSpeedAllowed(void) {
    return tapped();
}

// The speed's changes, oldest first: when each came and the speed before it, for speedCorrection.
// ponytail: the last 16 only. A state stamped before them runs its oldest part at the wrong speed, but every
// seek, skip and pause stamps a new one.
typedef struct {
    CFAbsoluteTime at;
    float before;
} SpeedChange;
enum { kSpeedChanges = 16 };
static SpeedChange sg_speedChanges[kSpeedChanges];
static unsigned sg_speedChangeCount;
static os_unfair_lock sg_speedChangesLock = OS_UNFAIR_LOCK_INIT;

void SGSetPlayerSpeed(double speed) {
    if (!tapped()) return;
    os_unfair_lock_lock(&sg_speedChangesLock);
    if ((float)speed != sg_speed) {
        sg_speedChanges[sg_speedChangeCount++ % kSpeedChanges] = (SpeedChange){CFAbsoluteTimeGetCurrent(), sg_speed};
    }
    sg_speed = (float)speed;
    storeFloat(&sg_speedBits, sg_speed);
    os_unfair_lock_unlock(&sg_speedChangesLock);
    apply();
}

// Song seconds that -position, running all the time since `stamp` at today's speed, counts too many (negative)
// or too few: each stretch before a change since then played at the speed before it.
static double speedCorrection(CFAbsoluteTime stamp) {
    double seconds = 0;
    os_unfair_lock_lock(&sg_speedChangesLock);
    float now = loadFloat(&sg_speedBits);
    CFAbsoluteTime from = stamp;
    for (unsigned i = MIN(sg_speedChangeCount, (unsigned)kSpeedChanges); i > 0; i--) {
        SpeedChange change = sg_speedChanges[(sg_speedChangeCount - i) % kSpeedChanges];
        if (change.at <= from) continue;
        seconds += (change.before - now) * (change.at - from);
        from = change.at;
    }
    os_unfair_lock_unlock(&sg_speedChangesLock);
    return seconds;
}

float SGPlayerPitch(void) {
    return sg_semitones;
}

void SGSetPlayerPitch(float semitones) {
    if (!sg_reachable && !tapped()) return;
    sg_semitones = semitones;
    apply();
}

BOOL SGPlayerPitchFollowsSpeed(void) {
    return SGEnabled(SGKeyPitchFollowsSpeed);
}

void SGSetPlayerPitchFollowsSpeed(BOOL follows) {
    SGSetEnabled(SGKeyPitchFollowsSpeed, follows);
    SGTimePitch *unit = atomic_load(&sg_pull);
    if (unit) SGTimePitchSetFollows(unit, follows);
    apply();
}

BOOL SGPlayerPitchAvailable(void) {
    return sg_reachable || tapped();
}

void SGPlayerSetGain(float gain) {
    if (!sg_reachable) {
        static int logged;
        if (logged++ < 1) SGLog(@"audio: Spotify's output was not reached, the gain cannot apply");
    }
    storeFloat(&sg_gainBits, fmaxf(0, fminf(gain, 1)));
}

AudioUnit SGPlayerMusicOutput(void) {
    Output *output = music();
    return output ? atomic_load(&output->unit) : NULL;
}

BOOL SGPlayerMusicClientFormat(AudioStreamBasicDescription *format) {
    pthread_mutex_lock(&sg_outputsLock);
    AudioUnit unit = SGPlayerMusicOutput();
    UInt32 size = sizeof *format;
    BOOL read = unit && AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, format, &size) == noErr;
    pthread_mutex_unlock(&sg_outputsLock);
    return read;
}

static void rebind(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        sg_secondsPerTick = (double)timebase.numer / timebase.denom / 1e9;
        sg_outputsQueue = dispatch_queue_create("spotifyglass.outputs", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
        if (!SGRebindImport("AudioUnitSetProperty", setProperty, (void **)&sg_setProperty) || !sg_setProperty) {
            sg_setProperty = NULL;
            SGLog(@"redesign speed: Spotify does not import AudioUnitSetProperty, the menu offers pitch only");
        }
        sg_reachable = SGRebindImport("AudioOutputUnitStart", startOutput, (void **)&sg_startOutput) && sg_startOutput;
        if (!sg_reachable) {
            SGLog(@"audio: Spotify does not import AudioOutputUnitStart, its output cannot be reached");
            return;
        }
        if (!SGRebindImport("AudioOutputUnitStop", stopOutput, (void **)&sg_stopOutput) || !sg_stopOutput) sg_stopOutput = AudioOutputUnitStop;
        if (!SGRebindImport("AudioComponentInstanceDispose", disposeUnit, (void **)&sg_dispose) || !sg_dispose) {
            sg_dispose = AudioComponentInstanceDispose;
            SGLog(@"audio: Spotify does not import AudioComponentInstanceDispose, a disposed output is not seen");
        }
    });
}

BOOL SGPlayerWatchMusicOutput(SGPlayerOutputWatcher watcher) {
    rebind();
    pthread_mutex_lock(&sg_outputsLock);
    for (int i = 0; i < kMaxWatchers; i++) {
        if (sg_watchers[i]) continue;
        sg_watchers[i] = watcher;
        break;
    }
    pthread_mutex_unlock(&sg_outputsLock);
    return sg_reachable;
}

#pragma mark - Spotify's clock

// Sing's -position asks [self position] again for the raw one, so this hook may run inside itself; only the
// outer one corrects.
static _Thread_local BOOL sg_correcting;

%hook SPTPlayerState
- (double)playbackSpeed {
    double speed = %orig;
    float ours = loadFloat(&sg_speedBits);
    return ours > 0 && ours != 1 ? speed * ours : speed;
}

- (double)position {
    if (sg_correcting) return %orig;
    sg_correcting = YES;
    double position = %orig;
    sg_correcting = NO;
    NSDate *stamp = self.timestamp;
    if (position < 0 || self.isPaused || !stamp) return position;
    double correction = speedCorrection(stamp.timeIntervalSinceReferenceDate);
    if (correction == 0) return position;
    // Spotify's own speed, a podcast's, runs under ours.
    float ours = loadFloat(&sg_speedBits);
    double rate = self.playbackSpeed, spotify = ours > 0 && ours != 1 ? rate / ours : rate;
    return MAX(0, position + correction * spotify);
}
%end

%ctor {
    storeFloat(&sg_speedBits, 1);
    storeFloat(&sg_gainBits, 1);
    rebind();
    %init;
    SGRequireClasses(@[@"SPTPlayerState"]);
}
