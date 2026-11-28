#include "internal.h"

#ifdef _WIN32

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* Windows fills small buffers with sound in turn, and tells Lucid's window each time one is
   full. Each is added to the recording and handed back to be filled again. */

#define RATE 16000
#define CHUNK 800            /* 50 ms */
#define CHUNKS 16
#define LONGEST (RATE * 60 * 30) /* half an hour */

static HWAVEIN device;
static WAVEHDR headers[CHUNKS];
static int16_t chunks[CHUNKS][CHUNK];
/* The buffer Windows will finish next. They are filled in the order they were handed over. */
static int next;

static SRWLOCK lock = SRWLOCK_INIT;
static int16_t *samples;
static size_t count;
static size_t capacity;
static volatile LONG level_millionths;
static volatile LONG pretend_millionths = -1;

static void enter(void) {
    AcquireSRWLockExclusive(&lock);
}

static void leave(void) {
    ReleaseSRWLockExclusive(&lock);
}

static void append(const int16_t *more, size_t length) {
    if (length == 0) return;
    double squares = 0;
    for (size_t index = 0; index < length; index++) {
        double value = (double)more[index] / 32768.0;
        squares += value * value;
    }
    InterlockedExchange(&level_millionths, (LONG)(sqrt(squares / (double)length) * 1000000.0));

    enter();
    if (count + length > capacity && capacity < LONGEST) {
        size_t wanted = capacity ? capacity * 2 : (size_t)RATE * 30;
        while (wanted < count + length) wanted *= 2;
        int16_t *grown = (int16_t *)realloc(samples, wanted * sizeof(int16_t));
        if (grown) {
            samples = grown;
            capacity = wanted;
        }
    }
    if (count + length <= capacity) {
        memcpy(samples + count, more, length * sizeof(int16_t));
        count += length;
    }
    leave();
}

/* Takes in every buffer Windows has finished. With `again`, each goes back to be refilled. */
static void drain(bool again) {
    for (int lap = 0; lap < CHUNKS; lap++) {
        WAVEHDR *header = &headers[next];
        if (!(header->dwFlags & WHDR_DONE)) return;
        append((const int16_t *)header->lpData, header->dwBytesRecorded / sizeof(int16_t));
        header->dwFlags &= ~(DWORD)WHDR_DONE;
        header->dwBytesRecorded = 0;
        if (again) waveInAddBuffer(device, header, sizeof *header);
        next = (next + 1) % CHUNKS;
    }
}

static void close_device(void) {
    if (!device) return;
    /* Hands back every buffer, the one being filled included. */
    waveInReset(device);
    drain(false);
    for (int index = 0; index < CHUNKS; index++) waveInUnprepareHeader(device, &headers[index], sizeof headers[index]);
    waveInClose(device);
    device = NULL;
    InterlockedExchange(&level_millionths, 0);
}

int lucid_mic_devices(void) {
    return (int)waveInGetNumDevs();
}

bool lucid_mic_allowed(void) {
    /* Windows 10 and 11 have a switch that keeps every app from the microphone, and a
       second one for apps like Lucid that do not come from the Store. */
    static const wchar_t *keys[] = {
        L"Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone",
        L"Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone\\NonPackaged",
    };
    for (size_t index = 0; index < LUCID_COUNT(keys); index++) {
        wchar_t value[32];
        if (lucid_registry_text(HKEY_CURRENT_USER, keys[index], L"Value", value, LUCID_COUNT(value))
            && lstrcmpiW(value, L"Deny") == 0) {
            return false;
        }
    }
    return true;
}

size_t lucid_mic_recorder(char *out, size_t room) {
    static const char name[] = "Windows";
    if (!out || room < sizeof name) return 0;
    memcpy(out, name, sizeof name);
    return sizeof name - 1;
}

bool lucid_mic_start(void) {
    close_device();
    enter();
    count = 0;
    leave();

    WAVEFORMATEX format;
    memset(&format, 0, sizeof format);
    format.wFormatTag = WAVE_FORMAT_PCM;
    format.nChannels = 1;
    format.nSamplesPerSec = RATE;
    format.wBitsPerSample = 16;
    format.nBlockAlign = 2;
    format.nAvgBytesPerSec = RATE * 2;
    /* The microphone chosen in Windows' sound settings. Windows converts from whatever it records at. */
    if (waveInOpen(&device, WAVE_MAPPER, &format, (DWORD_PTR)lucid_window, 0, CALLBACK_WINDOW) != MMSYSERR_NOERROR) {
        device = NULL;
        return false;
    }
    next = 0;
    for (int index = 0; index < CHUNKS; index++) {
        WAVEHDR *header = &headers[index];
        memset(header, 0, sizeof *header);
        header->lpData = (LPSTR)chunks[index];
        header->dwBufferLength = sizeof chunks[index];
        if (waveInPrepareHeader(device, header, sizeof *header) != MMSYSERR_NOERROR
            || waveInAddBuffer(device, header, sizeof *header) != MMSYSERR_NOERROR) {
            close_device();
            return false;
        }
    }
    if (waveInStart(device) != MMSYSERR_NOERROR) {
        close_device();
        return false;
    }
    return true;
}

void lucid_mic_data(HWAVEIN from) {
    /* A message about a recording that has since ended is of no use. */
    if (device && from == device) drain(true);
}

size_t lucid_mic_count(void) {
    enter();
    size_t held = count;
    leave();
    return held;
}

size_t lucid_mic_latest(int16_t *out, size_t wanted) {
    if (!out) return 0;
    enter();
    size_t length = count < wanted ? count : wanted;
    if (length > 0) memcpy(out, samples + (count - length), length * sizeof(int16_t));
    leave();
    return length;
}

size_t lucid_mic_stop(void) {
    close_device();
    return lucid_mic_count();
}

size_t lucid_mic_take(int16_t *out, size_t wanted) {
    enter();
    size_t length = count < wanted ? count : wanted;
    if (out && length > 0) memcpy(out, samples, length * sizeof(int16_t));
    count = 0;
    /* A long recording is not worth keeping the memory for. */
    if (capacity > (size_t)RATE * 120) {
        free(samples);
        samples = NULL;
        capacity = 0;
    }
    leave();
    return length;
}

float lucid_mic_level(void) {
    LONG pretend = pretend_millionths;
    return (float)(pretend >= 0 ? pretend : level_millionths) / 1000000.0f;
}

void lucid_test_level(float level) {
    InterlockedExchange(&pretend_millionths, level < 0 ? -1 : (LONG)(level * 1000000.0f));
}

#endif
