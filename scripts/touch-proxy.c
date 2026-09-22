/*
 * touch-proxy (fork-aligned): QEMU usb-tablet -> MT type-B for QtCar's TouchDriver.
 * Based on denysvitali/tesla-qemu tools/touch-proxy.c (proven for this exact
 * libQtCarUIFramework SHA), plus the nudge fix from x11-input-proxy.c (the
 * root-cause fix: the kernel silently drops ABS events whose value is
 * unchanged from the last report, so emit a 1-unit-off sentinel position
 * first to force the real coordinate through).
 *
 * KEY: TOUCH_X_MAX/Y_MAX = 1200x1920 (the real Tesla panel coordinate space
 * QtCarTouchDriver expects), NOT the display resolution.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <errno.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <sys/ioctl.h>

#define TABLET_MAX 32767
#define TOUCH_X_MAX 1200
#define TOUCH_Y_MAX 1920
#define RETRY_MAX     30
#define RETRY_DELAY_S  1

static int try_find_tablet(void)
{
    DIR *dir; struct dirent *ent; char path[64]; int fd;
    unsigned long evbits[2] = {0}, absbits[2] = {0}; char name[256] = {0};
    dir = opendir("/dev/input");
    if (!dir) return -1;
    while ((ent = readdir(dir)) != NULL) {
        if (strncmp(ent->d_name, "event", 5) != 0) continue;
        snprintf(path, sizeof(path), "/dev/input/%s", ent->d_name);
        fd = open(path, O_RDONLY);
        if (fd < 0) continue;
        if (ioctl(fd, EVIOCGBIT(0, sizeof(evbits)), evbits) < 0) { close(fd); continue; }
        if (!(evbits[0] & (1 << EV_ABS))) { close(fd); continue; }
        if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(absbits)), absbits) < 0) { close(fd); continue; }
        if ((absbits[0] & (1 << ABS_X)) && (absbits[0] & (1 << ABS_Y))) {
            ioctl(fd, EVIOCGNAME(sizeof(name)), name);
            /* prefer the QEMU tablet, skip our own proxy / keyboards */
            if (strstr(name, "QEMU") || strstr(name, "Tablet")) {
                fprintf(stderr, "touch-proxy: found tablet: %s (%s)\n", path, name);
                closedir(dir); return fd;
            }
        }
        close(fd);
    }
    closedir(dir);
    return -1;
}

static int find_tablet_device(void)
{
    int fd, i;
    for (i = 0; i < RETRY_MAX; i++) {
        fd = try_find_tablet();
        if (fd >= 0) return fd;
        if (i == 0) fprintf(stderr, "touch-proxy: waiting for tablet...\n");
        sleep(RETRY_DELAY_S);
    }
    return -1;
}

static int create_uinput_device(void)
{
    int fd; struct uinput_setup setup; struct uinput_abs_setup abs_setup;
    fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) { perror("open /dev/uinput"); return -1; }

    ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT);
    /* EV_ABS + EV_SYN only — parseData() ignores EV_KEY (fork's finding) */
    ioctl(fd, UI_SET_EVBIT, EV_ABS);
    ioctl(fd, UI_SET_EVBIT, EV_SYN);

    memset(&abs_setup, 0, sizeof(abs_setup));
    abs_setup.code = ABS_MT_SLOT; abs_setup.absinfo.minimum = 0; abs_setup.absinfo.maximum = 0;
    ioctl(fd, UI_ABS_SETUP, &abs_setup);
    memset(&abs_setup, 0, sizeof(abs_setup));
    abs_setup.code = ABS_MT_TRACKING_ID; abs_setup.absinfo.minimum = 0; abs_setup.absinfo.maximum = 65535;
    ioctl(fd, UI_ABS_SETUP, &abs_setup);
    memset(&abs_setup, 0, sizeof(abs_setup));
    abs_setup.code = ABS_MT_POSITION_X; abs_setup.absinfo.minimum = 0; abs_setup.absinfo.maximum = TOUCH_X_MAX;
    ioctl(fd, UI_ABS_SETUP, &abs_setup);
    memset(&abs_setup, 0, sizeof(abs_setup));
    abs_setup.code = ABS_MT_POSITION_Y; abs_setup.absinfo.minimum = 0; abs_setup.absinfo.maximum = TOUCH_Y_MAX;
    ioctl(fd, UI_ABS_SETUP, &abs_setup);

    memset(&setup, 0, sizeof(setup));
    snprintf(setup.name, UINPUT_MAX_NAME_SIZE, "Tesla Touch Proxy");
    setup.id.bustype = BUS_VIRTUAL; setup.id.vendor = 0x1234; setup.id.product = 0x5678; setup.id.version = 1;
    if (ioctl(fd, UI_DEV_SETUP, &setup) < 0) { perror("UI_DEV_SETUP"); close(fd); return -1; }
    if (ioctl(fd, UI_DEV_CREATE) < 0) { perror("UI_DEV_CREATE"); close(fd); return -1; }
    fprintf(stderr, "touch-proxy: created uinput device 'Tesla Touch Proxy' (%dx%d)\n",
            TOUCH_X_MAX, TOUCH_Y_MAX);
    return fd;
}

static void emit(int fd, unsigned short type, unsigned short code, int value)
{
    struct input_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = type; ev.code = code; ev.value = value;
    if (write(fd, &ev, sizeof(ev)) != sizeof(ev)) { /* ignore */ }
}

/* nudge: emit a 1-unit-off position before the real one so the kernel's
 * input_handle_abs_event() dedup filter always sees a change and never
 * drops the real coordinate (root-cause fix from x11-input-proxy.c). */
static void emit_touch_position(int fd, int tx, int ty)
{
    int nx = tx > 0 ? tx - 1 : tx + 1;
    int ny = ty > 0 ? ty - 1 : ty + 1;
    emit(fd, EV_ABS, ABS_MT_POSITION_X, nx);
    emit(fd, EV_ABS, ABS_MT_POSITION_Y, ny);
    emit(fd, EV_ABS, ABS_MT_POSITION_X, tx);
    emit(fd, EV_ABS, ABS_MT_POSITION_Y, ty);
}

static inline int scale(int value, int in_max, int out_max)
{
    return (int)((long)value * out_max / in_max);
}

int main(void)
{
    int in_fd, out_fd;
    struct input_event ev;
    int tracking_id = 0, touch_active = 0, cur_x = 0, cur_y = 0, x_dirty = 0, y_dirty = 0;

    in_fd = find_tablet_device();
    if (in_fd < 0) { fprintf(stderr, "touch-proxy: no tablet device\n"); return 1; }
    out_fd = create_uinput_device();
    if (out_fd < 0) { close(in_fd); return 1; }
    fprintf(stderr, "touch-proxy: running event loop\n");

    while (read(in_fd, &ev, sizeof(ev)) == sizeof(ev)) {
        switch (ev.type) {
        case EV_KEY:
            if (ev.code == BTN_LEFT || ev.code == BTN_TOUCH) {
                if (ev.value && !touch_active) {
                    touch_active = 1; x_dirty = 0; y_dirty = 0;
                    emit(out_fd, EV_ABS, ABS_MT_SLOT, 0);
                    emit(out_fd, EV_ABS, ABS_MT_TRACKING_ID, tracking_id++);
                    emit_touch_position(out_fd, cur_x, cur_y);
                } else if (!ev.value && touch_active) {
                    touch_active = 0; x_dirty = 0; y_dirty = 0;
                    emit(out_fd, EV_ABS, ABS_MT_SLOT, 0);
                    emit(out_fd, EV_ABS, ABS_MT_TRACKING_ID, -1);
                }
            }
            break;
        case EV_ABS:
            if (ev.code == ABS_X) { cur_x = scale(ev.value, TABLET_MAX, TOUCH_X_MAX); if (touch_active) x_dirty = 1; }
            else if (ev.code == ABS_Y) { cur_y = scale(ev.value, TABLET_MAX, TOUCH_Y_MAX); if (touch_active) y_dirty = 1; }
            break;
        case EV_SYN:
            if (ev.code == SYN_REPORT) {
                if (touch_active && (x_dirty || y_dirty)) {
                    emit(out_fd, EV_ABS, ABS_MT_SLOT, 0);
                    emit_touch_position(out_fd, cur_x, cur_y);
                    x_dirty = 0; y_dirty = 0;
                }
                emit(out_fd, EV_SYN, SYN_REPORT, 0);
            }
            break;
        }
    }
    ioctl(out_fd, UI_DEV_DESTROY);
    close(in_fd); close(out_fd);
    return 0;
}
