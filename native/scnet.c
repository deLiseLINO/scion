/*
 * The AVF guest's network (the Network setting with the AVF backend, docs/NETWORKING.md):
 * libslirp on one end of a virtio socket stream, the guest kernel's en0 on the other
 * (scion-kernel drivers/virtio/hakios.virtio_net.c, boot-arg virtio_net_vsock=PORT). slirp
 * answers the guest's DHCP (10.0.2.15, router 10.0.2.2, DNS 10.0.2.3) and carries its TCP and
 * UDP through this app's own sockets, so the guest reaches whatever network the phone has.
 *
 * The stream carries one structure, both ways: a frame's length as a 32-bit big-endian number
 * (1..FRAME_MAX), then the Ethernet frame without its checksum; again and again. The stream cuts
 * the bytes up as it likes, so frames are put back together here; a length out of range ends
 * the session.
 *
 * Avf/Scnet.kt connects (VirtualMachine.connectVsock), passes the socket here, and calls run()
 * on a thread of its own; run() returns when the stream ends or stop() is called, and closes the
 * socket. One session at a time, one thread: slirp is not thread-safe, and nothing else touches it.
 * DNS: slirp forwards the guest's queries to the servers in the file named by SLIRP_RESOLV_CONF
 * (native/patches/libslirp-android.patch), which the app keeps current (QemuNet.Resolver).
 *
 * Built by native/build-android.sh into jniLibs as libscnet.so, with the static libslirp and glib.
 */
#define _GNU_SOURCE             /* pipe2 */
#include <android/log.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <jni.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

#include <libslirp.h>

#define TAG "scnet"
#define LOG(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define PREFIX 4
#define FRAME_MAX 1514          /* the guest's HAKIOS_NET_FRAME_MAX: 1500 bytes of IP and the Ethernet header */
#define READ_SIZE 65536

struct timer {
    SlirpTimerId id;
    void *cb_opaque;
    int64_t expire_ms;          /* -1: not armed */
    struct timer *next;
};

struct session {
    Slirp *slirp;
    int fd;
    struct pollfd *pfds;
    int npfds, room;
    struct timer *timers;
    uint8_t frame[PREFIX + FRAME_MAX];
    uint32_t have;
    uint64_t frames_in, frames_out, bytes_in, bytes_out;
    const char *ended;          /* why the session is over, once it is */
};

/* stop(): the running session's wake-up pipe, and whether it was asked to end */
static int wake_fds[2] = { -1, -1 };
static atomic_bool stopping;

static int64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* ---- slirp's callbacks ---- */

/* A frame for the guest: its length, then the frame, in one write. */
static slirp_ssize_t send_packet(const void *buf, size_t len, void *opaque)
{
    struct session *s = opaque;
    uint8_t prefix[PREFIX] = { (uint8_t)(len >> 24), (uint8_t)(len >> 16), (uint8_t)(len >> 8), (uint8_t)len };
    struct iovec iov[2] = { { prefix, PREFIX }, { (void *)buf, len } };
    size_t left = PREFIX + len;

    if (len == 0 || len > FRAME_MAX || s->ended) {
        return (slirp_ssize_t)len;      /* (slirp never makes one bigger than its MTU allows) */
    }
    while (left > 0) {
        ssize_t n = writev(s->fd, iov, 2);
        if (n < 0) {
            if (errno == EINTR) continue;
            s->ended = "the guest's stream refused a write";
            LOG("write: %s", strerror(errno));
            return -1;
        }
        left -= (size_t)n;
        for (int i = 0; i < 2 && n > 0; i++) {
            size_t take = (size_t)n < iov[i].iov_len ? (size_t)n : iov[i].iov_len;
            iov[i].iov_base = (uint8_t *)iov[i].iov_base + take;
            iov[i].iov_len -= take;
            n -= (ssize_t)take;
        }
    }
    s->frames_out++;
    s->bytes_out += len;
    return (slirp_ssize_t)len;
}

static void guest_error(const char *msg, void *opaque)
{
    (void)opaque;
    LOG("guest error: %s", msg);
}

static int64_t clock_get_ns(void *opaque)
{
    (void)opaque;
    return now_ms() * 1000000;
}

static void *timer_new_opaque(SlirpTimerId id, void *cb_opaque, void *opaque)
{
    struct session *s = opaque;
    struct timer *t = calloc(1, sizeof(*t));

    if (t == NULL) return NULL;
    t->id = id;
    t->cb_opaque = cb_opaque;
    t->expire_ms = -1;
    t->next = s->timers;
    s->timers = t;
    return t;
}

static void timer_free(void *timer, void *opaque)
{
    struct session *s = opaque;

    for (struct timer **p = &s->timers; *p != NULL; p = &(*p)->next) {
        if (*p == timer) {
            *p = ((struct timer *)timer)->next;
            free(timer);
            return;
        }
    }
}

static void timer_mod(void *timer, int64_t expire_ms, void *opaque)
{
    (void)opaque;
    ((struct timer *)timer)->expire_ms = expire_ms;
}

static void poll_socket(slirp_os_socket fd, void *opaque)
{
    (void)fd;
    (void)opaque;               /* every loop asks slirp for its sockets anew */
}

static void notify(void *opaque)
{
    (void)opaque;
    if (wake_fds[1] >= 0) {
        (void)write(wake_fds[1], "n", 1);
    }
}

static const SlirpCb callbacks = {
    .send_packet = send_packet,
    .guest_error = guest_error,
    .clock_get_ns = clock_get_ns,
    .timer_free = timer_free,
    .timer_mod = timer_mod,
    .notify = notify,
    .timer_new_opaque = timer_new_opaque,
    .register_poll_socket = poll_socket,
    .unregister_poll_socket = poll_socket,
};

/* ---- the loop ---- */

static int add_poll(slirp_os_socket fd, int events, void *opaque)
{
    struct session *s = opaque;
    short e = 0;

    if (s->npfds == s->room) {
        int room = s->room ? s->room * 2 : 64;
        struct pollfd *p = realloc(s->pfds, (size_t)room * sizeof(*p));
        if (p == NULL) return -1;
        s->pfds = p;
        s->room = room;
    }
    if (events & SLIRP_POLL_IN) e |= POLLIN;
    if (events & SLIRP_POLL_OUT) e |= POLLOUT;
    if (events & SLIRP_POLL_PRI) e |= POLLPRI;
    s->pfds[s->npfds] = (struct pollfd){ .fd = fd, .events = e };
    return s->npfds++;
}

static int get_revents(int idx, void *opaque)
{
    struct session *s = opaque;
    short r;
    int e = 0;

    if (idx < 0 || idx >= s->npfds) return 0;
    r = s->pfds[idx].revents;
    if (r & POLLIN) e |= SLIRP_POLL_IN;
    if (r & POLLOUT) e |= SLIRP_POLL_OUT;
    if (r & POLLPRI) e |= SLIRP_POLL_PRI;
    if (r & POLLERR) e |= SLIRP_POLL_ERR;
    if (r & POLLHUP) e |= SLIRP_POLL_HUP;
    return e;
}

/* Bytes of the stream: the frames in them to slirp. False if they are not frames. */
static bool from_guest(struct session *s, const uint8_t *p, size_t n)
{
    while (n > 0) {
        uint32_t want = PREFIX, take;

        if (s->have >= PREFIX) {
            uint32_t length = (uint32_t)s->frame[0] << 24 | (uint32_t)s->frame[1] << 16 |
                (uint32_t)s->frame[2] << 8 | s->frame[3];
            if (length == 0 || length > FRAME_MAX) {
                LOG("the guest sent a frame length of %u", length);
                return false;
            }
            want = PREFIX + length;
        }
        take = want - s->have < n ? want - s->have : (uint32_t)n;
        memcpy(s->frame + s->have, p, take);
        s->have += take;
        p += take;
        n -= take;
        if (s->have == want && want > PREFIX) {
            if (s->frames_in++ == 0) LOG("the guest's first frame: %u bytes", want - PREFIX);
            s->bytes_in += want - PREFIX;
            slirp_input(s->slirp, s->frame + PREFIX, (int)(want - PREFIX));
            s->have = 0;
        }
    }
    return true;
}

static void run_timers(struct session *s)
{
    int64_t now = now_ms();
    bool again = true;

    /* a timer's callback may arm, add or free timers: start over after each */
    while (again) {
        again = false;
        for (struct timer *t = s->timers; t != NULL; t = t->next) {
            if (t->expire_ms >= 0 && t->expire_ms <= now) {
                t->expire_ms = -1;
                slirp_handle_timer(s->slirp, t->id, t->cb_opaque);
                again = true;
                break;
            }
        }
    }
}

static void loop(struct session *s)
{
    static uint8_t buffer[READ_SIZE];
    int64_t said_at = now_ms();
    uint64_t said = 0;

    while (s->ended == NULL) {
        uint32_t timeout = 1000;
        int64_t now = now_ms();
        int ready;

        /* to logcat every 30 s while frames move: whether the guest talks at all */
        if (now - said_at >= 30000 && s->frames_in + s->frames_out != said) {
            said = s->frames_in + s->frames_out;
            said_at = now;
            LOG("%llu frames from the guest (%llu bytes), %llu to it (%llu bytes)",
                (unsigned long long)s->frames_in, (unsigned long long)s->bytes_in,
                (unsigned long long)s->frames_out, (unsigned long long)s->bytes_out);
        }
        s->npfds = 0;
        add_poll(s->fd, SLIRP_POLL_IN, s);              /* index 0: the guest */
        add_poll(wake_fds[0], SLIRP_POLL_IN, s);        /* index 1: stop() and slirp's notify */
        slirp_pollfds_fill_socket(s->slirp, &timeout, add_poll, s);
        for (struct timer *t = s->timers; t != NULL; t = t->next) {
            if (t->expire_ms >= 0) {
                int64_t in = t->expire_ms > now ? t->expire_ms - now : 0;
                if (in < timeout) timeout = (uint32_t)in;
            }
        }
        ready = poll(s->pfds, (nfds_t)s->npfds, (int)timeout);
        if (ready < 0 && errno != EINTR) {
            s->ended = "poll failed";
            LOG("poll: %s", strerror(errno));
            break;
        }
        if (ready > 0 && (s->pfds[1].revents & POLLIN)) {
            char drain[64];
            while (read(wake_fds[0], drain, sizeof(drain)) > 0) {
            }
        }
        if (atomic_load(&stopping)) {
            s->ended = "stopped by the app";
            break;
        }
        if (ready > 0 && (s->pfds[0].revents & (POLLIN | POLLHUP | POLLERR))) {
            ssize_t n = recv(s->fd, buffer, sizeof(buffer), MSG_DONTWAIT);
            if (n == 0) {
                s->ended = "the guest's end closed";
            } else if (n < 0 && errno != EAGAIN && errno != EINTR) {
                s->ended = "the guest's stream failed";
                LOG("read: %s", strerror(errno));
            } else if (n > 0 && !from_guest(s, buffer, (size_t)n)) {
                s->ended = "what the guest sent was not frames";
            }
        }
        slirp_pollfds_poll(s->slirp, ready < 0, get_revents, s);
        run_timers(s);
    }
}

/* ---- JNI: io.github.dylanneve1.iosonpixel.avf.ScnetNative ---- */

JNIEXPORT jstring JNICALL
Java_io_github_dylanneve1_iosonpixel_avf_ScnetNative_run(JNIEnv *env, jclass cls, jint fd)
{
    struct session s = { .fd = fd };
    SlirpConfig cfg = {
        .version = 6,
        .in_enabled = true,
        .disable_host_loopback = true,  /* the phone's own 127.0.0.1 is not the guest's business */
        .if_mtu = 1500,
        .if_mru = 1500,
    };
    char text[256];

    (void)cls;
    inet_pton(AF_INET, "10.0.2.0", &cfg.vnetwork);
    inet_pton(AF_INET, "255.255.255.0", &cfg.vnetmask);
    inet_pton(AF_INET, "10.0.2.2", &cfg.vhost);
    inet_pton(AF_INET, "10.0.2.15", &cfg.vdhcp_start);
    inet_pton(AF_INET, "10.0.2.3", &cfg.vnameserver);
    atomic_store(&stopping, false);
    if (pipe2(wake_fds, O_CLOEXEC | O_NONBLOCK) != 0) {
        close(fd);
        return (*env)->NewStringUTF(env, "no pipe for the loop");
    }
    s.slirp = slirp_new(&cfg, &callbacks, &s);
    if (s.slirp == NULL) {
        s.ended = "slirp did not start";
    } else {
        LOG("session on fd %d", fd);
        loop(&s);
        slirp_cleanup(s.slirp);
    }
    while (s.timers != NULL) {
        struct timer *t = s.timers;
        s.timers = t->next;
        free(t);
    }
    free(s.pfds);
    close(fd);
    close(wake_fds[0]);
    close(wake_fds[1]);
    wake_fds[0] = wake_fds[1] = -1;
    snprintf(text, sizeof(text), "%s; %llu frames from the guest (%llu bytes), %llu to it (%llu bytes)", s.ended,
        (unsigned long long)s.frames_in, (unsigned long long)s.bytes_in,
        (unsigned long long)s.frames_out, (unsigned long long)s.bytes_out);
    LOG("%s", text);
    return (*env)->NewStringUTF(env, text);
}

JNIEXPORT void JNICALL
Java_io_github_dylanneve1_iosonpixel_avf_ScnetNative_stop(JNIEnv *env, jclass cls)
{
    (void)env;
    (void)cls;
    atomic_store(&stopping, true);
    notify(NULL);
}
