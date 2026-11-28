#include "internal.h"

#ifdef __linux__

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

/* Recording is done by one of the small programs that come with a Linux desktop's sound
   system. It writes what the microphone hears to a pipe, and a thread here reads it. That
   way Lucid needs none of the sound systems to be built, and works with any of them. */

#define RATE 16000
#define LONGEST (RATE * 60 * 30) /* half an hour */

extern char **environ;

typedef struct {
    const char *program;
    const char *arguments[12];
} Recorder;

/* In the order they are tried. All record 16 kHz, one channel, 16 bits, without a header. */
static const Recorder recorders[] = {
    /* PulseAudio, and PipeWire answering for it, which is most desktops. */
    {"parec", {"parec", "--raw", "--format=s16le", "--rate=16000", "--channels=1", "--latency-msec=30", "--client-name=Lucid", NULL}},
    {"pw-record", {"pw-record", "--raw", "--format=s16", "--rate=16000", "--channels=1", "--latency=30ms", "-", NULL}},
    {"arecord", {"arecord", "-q", "-t", "raw", "-f", "S16_LE", "-r", "16000", "-c", "1", NULL}},
};

static pid_t child;
static int child_output = -1;
static pthread_t reader;
static bool reading;

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int16_t *samples;
static size_t count;
static size_t room;
static volatile int level_millionths;
static volatile int pretend_millionths = -1;

static const Recorder *find_recorder(void) {
    /* For tests, and for anyone whose sound system needs something else. */
    const char *wanted = g_getenv("LUCID_RECORDER");
    for (size_t index = 0; index < G_N_ELEMENTS(recorders); index++) {
        if (wanted && wanted[0] && strcmp(wanted, recorders[index].program) != 0) continue;
        char *path = g_find_program_in_path(recorders[index].program);
        if (!path) continue;
        g_free(path);
        return &recorders[index];
    }
    return NULL;
}

size_t lucid_mic_recorder(char *out, size_t capacity) {
    if (!out || capacity == 0) return 0;
    const Recorder *recorder = find_recorder();
    g_strlcpy(out, recorder ? recorder->program : "", capacity);
    return strlen(out);
}

static void append(const int16_t *more, size_t length) {
    if (length == 0) return;
    double squares = 0;
    for (size_t index = 0; index < length; index++) {
        double value = (double)more[index] / 32768.0;
        squares += value * value;
    }
    level_millionths = (int)(sqrt(squares / (double)length) * 1000000.0);

    pthread_mutex_lock(&lock);
    if (count + length > room && room < LONGEST) {
        size_t wanted = room ? room * 2 : (size_t)RATE * 30;
        while (wanted < count + length) wanted *= 2;
        int16_t *grown = (int16_t *)realloc(samples, wanted * sizeof(int16_t));
        if (grown) {
            samples = grown;
            room = wanted;
        }
    }
    if (count + length <= room) {
        memcpy(samples + count, more, length * sizeof(int16_t));
        count += length;
    }
    pthread_mutex_unlock(&lock);
}

static void *read_sound(void *unused) {
    (void)unused;
    /* A read can end in the middle of a sample. The odd byte waits here for its other half. */
    unsigned char buffer[3200 + 1];
    size_t kept = 0;
    for (;;) {
        ssize_t got = read(child_output, buffer + kept, sizeof buffer - 1 - kept);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) break;
        size_t have = kept + (size_t)got;
        append((const int16_t *)(const void *)buffer, have / 2);
        kept = have % 2;
        if (kept) buffer[0] = buffer[have - 1];
    }
    return NULL;
}

/* Ends the recording program and takes in what it had still to say. */
static void end_recording(void) {
    if (child > 0) {
        kill(child, SIGTERM);
        /* It stops at once as a rule. One that does not is stopped by force, so that
           whoever is waiting here, which is the whole app, is not kept for long. */
        int status = 0;
        bool gone = false;
        for (int attempt = 0; attempt < 40 && !gone; attempt++) {
            gone = waitpid(child, &status, WNOHANG) != 0;
            if (!gone) g_usleep(10000);
        }
        if (!gone) {
            kill(child, SIGKILL);
            waitpid(child, &status, 0);
        }
    }
    child = 0;
    /* With the program gone, the pipe ends, and the reader with it. */
    if (reading) {
        pthread_join(reader, NULL);
        reading = false;
    }
    if (child_output >= 0) close(child_output);
    child_output = -1;
    level_millionths = 0;
}

/* How many microphones the sound system has, as last heard. -1 before it has answered. */
static volatile int known_devices = -1;
static volatile int asking;
static gint64 asked;

/* Asks the sound system, on a thread of its own: it can take its time to answer, and the
   one asking may be the thread that the dictation key and the pill depend on. */
static void *count_devices(void *unused) {
    (void)unused;
    char *output = NULL;
    gint status = 0;
    char *arguments[] = {(char *)"pactl", (char *)"list", (char *)"short", (char *)"sources", NULL};
    if (g_spawn_sync(NULL, arguments, NULL, G_SPAWN_SEARCH_PATH | G_SPAWN_STDERR_TO_DEV_NULL, NULL, NULL,
                     &output, NULL, &status, NULL)
        && status == 0 && output) {
        /* One line for each place sound can come from. The ones named ".monitor" are the
           loudspeakers listened back to, not microphones. */
        int found = 0;
        char **lines = g_strsplit(output, "\n", -1);
        for (char **line = lines; *line; line++) {
            char **fields = g_strsplit(*line, "\t", 3);
            if (fields[0] && fields[1] && !g_str_has_suffix(fields[1], ".monitor")) found++;
            g_strfreev(fields);
        }
        g_strfreev(lines);
        g_atomic_int_set(&known_devices, found);
    } else {
        /* No way to ask. There is something to record with, so assume a microphone. */
        g_atomic_int_set(&known_devices, 1);
    }
    g_free(output);
    g_atomic_int_set(&asking, 0);
    return NULL;
}

int lucid_mic_devices(void) {
    if (!find_recorder()) return 0;
    /* The answer rarely changes, so one a few seconds old will do, and nobody waits. */
    gint64 now = g_get_monotonic_time();
    gint64 last = asked;
    if ((last == 0 || now - last > 5 * G_USEC_PER_SEC) && g_atomic_int_compare_and_exchange(&asking, 0, 1)) {
        asked = now;
        pthread_t asker;
        if (pthread_create(&asker, NULL, count_devices, NULL) == 0) pthread_detach(asker);
        else g_atomic_int_set(&asking, 0);
    }
    int known = g_atomic_int_get(&known_devices);
    /* Not heard yet: there is something to record with, so assume a microphone. */
    return known < 0 ? 1 : known;
}

bool lucid_mic_allowed(void) {
    return true;
}

bool lucid_mic_start(void) {
    end_recording();
    pthread_mutex_lock(&lock);
    count = 0;
    pthread_mutex_unlock(&lock);

    const Recorder *recorder = find_recorder();
    if (!recorder) return false;
    /* Closed in every other program Lucid starts meanwhile: one that kept the far end open
       would keep the pipe from ever ending. */
    int ends[2];
    if (pipe2(ends, O_CLOEXEC) != 0) return false;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, ends[1], STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    pid_t started = 0;
    int failed = posix_spawnp(&started, recorder->program, &actions, NULL, (char *const *)recorder->arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(ends[1]);
    if (failed != 0) {
        close(ends[0]);
        return false;
    }
    child = started;
    child_output = ends[0];
    if (pthread_create(&reader, NULL, read_sound, NULL) != 0) {
        end_recording();
        return false;
    }
    reading = true;
    return true;
}

size_t lucid_mic_count(void) {
    pthread_mutex_lock(&lock);
    size_t held = count;
    pthread_mutex_unlock(&lock);
    return held;
}

size_t lucid_mic_latest(int16_t *out, size_t wanted) {
    if (!out) return 0;
    pthread_mutex_lock(&lock);
    size_t length = count < wanted ? count : wanted;
    if (length > 0) memcpy(out, samples + (count - length), length * sizeof(int16_t));
    pthread_mutex_unlock(&lock);
    return length;
}

size_t lucid_mic_stop(void) {
    end_recording();
    return lucid_mic_count();
}

size_t lucid_mic_take(int16_t *out, size_t wanted) {
    pthread_mutex_lock(&lock);
    size_t length = count < wanted ? count : wanted;
    if (out && length > 0) memcpy(out, samples, length * sizeof(int16_t));
    count = 0;
    /* A long recording is not worth keeping the memory for. */
    if (room > (size_t)RATE * 120) {
        free(samples);
        samples = NULL;
        room = 0;
    }
    pthread_mutex_unlock(&lock);
    return length;
}

float lucid_mic_level(void) {
    int pretend = pretend_millionths;
    return (float)(pretend >= 0 ? pretend : level_millionths) / 1000000.0f;
}

void lucid_test_level(float level) {
    pretend_millionths = level < 0 ? -1 : (int)(level * 1000000.0f);
}

#endif
