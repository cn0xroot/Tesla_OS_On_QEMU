/*
 * x11-input-proxy: Reads QEMU usb-tablet evdev events and injects them
 * into X11 via XTest extension.
 *
 * This bypasses all Xorg input driver configuration issues. It directly
 * opens the evdev device and uses XTestFakeMotionEvent / XTestFakeButtonEvent
 * to inject mouse movement and clicks into the X server.
 *
 * Also creates a uinput multitouch device at /dev/input/touch for QtCar's
 * TouchDriver (if it ever loads).
 *
 * Build (dynamic, runs inside VM with Tesla's X11 libs):
 *   gcc -o x11-input-proxy x11-input-proxy.c -lX11 -lXtst
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <sys/ioctl.h>
#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>

#define TABLET_MAX 32767

/* --- evdev device detection --- */

static int find_tablet_device(void)
{
    DIR *dir;
    struct dirent *ent;
    char path[64];
    int fd, i;
    unsigned long evbits[2], absbits[2];
    char name[256];
    /* Track a fallback in case no device has "QEMU"/"Tablet" in name */
    int fallback_fd = -1;
    char fallback_name[256] = {0};

    for (i = 0; i < 30; i++) {
        dir = opendir("/dev/input");
        if (!dir) {
            sleep(1);
            continue;
        }
        while ((ent = readdir(dir)) != NULL) {
            if (strncmp(ent->d_name, "event", 5) != 0)
                continue;
            snprintf(path, sizeof(path), "/dev/input/%s", ent->d_name);
            fd = open(path, O_RDONLY);
            if (fd < 0) continue;

            memset(evbits, 0, sizeof(evbits));
            memset(absbits, 0, sizeof(absbits));
            if (ioctl(fd, EVIOCGBIT(0, sizeof(evbits)), evbits) >= 0 &&
                (evbits[0] & (1 << EV_ABS)) &&
                ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(absbits)), absbits) >= 0 &&
                (absbits[0] & (1 << ABS_X)) && (absbits[0] & (1 << ABS_Y))) {
                memset(name, 0, sizeof(name));
                ioctl(fd, EVIOCGNAME(sizeof(name)), name);

                /* Skip our own uinput device */
                if (strstr(name, "Tesla Touch Proxy")) {
                    fprintf(stderr, "x11-input-proxy: skipping own device: %s (%s)\n", path, name);
                    close(fd);
                    continue;
                }

                /* Prefer QEMU tablet device */
                if (strstr(name, "QEMU") || strstr(name, "Tablet") || strstr(name, "tablet")) {
                    fprintf(stderr, "x11-input-proxy: found QEMU tablet: %s (%s)\n", path, name);
                    if (fallback_fd >= 0) close(fallback_fd);
                    closedir(dir);
                    return fd;
                }

                /* Keep as fallback */
                if (fallback_fd < 0) {
                    fallback_fd = fd;
                    strncpy(fallback_name, name, sizeof(fallback_name) - 1);
                    fprintf(stderr, "x11-input-proxy: candidate device: %s (%s)\n", path, name);
                } else {
                    close(fd);
                }
            } else {
                close(fd);
            }
        }
        closedir(dir);

        if (fallback_fd >= 0) {
            fprintf(stderr, "x11-input-proxy: using fallback device: %s\n", fallback_name);
            return fallback_fd;
        }

        if (i == 0) fprintf(stderr, "x11-input-proxy: waiting for tablet...\n");
        sleep(1);
    }
    return -1;
}

/* --- uinput touchscreen (for QtCar TouchDriver) --- */

#define TOUCH_X_MAX 1920
#define TOUCH_Y_MAX 1200

static int create_uinput_device(void)
{
    int fd;
    struct uinput_setup setup;
    struct uinput_abs_setup abs;

    fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) return -1;

    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_EVBIT, EV_ABS);
    ioctl(fd, UI_SET_EVBIT, EV_SYN);
    ioctl(fd, UI_SET_KEYBIT, BTN_TOUCH);

    memset(&abs, 0, sizeof(abs));
    abs.code = ABS_MT_SLOT; abs.absinfo.maximum = 0;
    ioctl(fd, UI_ABS_SETUP, &abs);
    abs.code = ABS_MT_TRACKING_ID; abs.absinfo.maximum = 65535;
    ioctl(fd, UI_ABS_SETUP, &abs);
    abs.code = ABS_MT_POSITION_X; abs.absinfo.maximum = TOUCH_X_MAX;
    ioctl(fd, UI_ABS_SETUP, &abs);
    abs.code = ABS_MT_POSITION_Y; abs.absinfo.maximum = TOUCH_Y_MAX;
    ioctl(fd, UI_ABS_SETUP, &abs);
    abs.code = ABS_X; abs.absinfo.maximum = TOUCH_X_MAX;
    ioctl(fd, UI_ABS_SETUP, &abs);
    abs.code = ABS_Y; abs.absinfo.maximum = TOUCH_Y_MAX;
    ioctl(fd, UI_ABS_SETUP, &abs);

    memset(&setup, 0, sizeof(setup));
    snprintf(setup.name, UINPUT_MAX_NAME_SIZE, "Tesla Touch Proxy");
    setup.id.bustype = BUS_VIRTUAL;
    setup.id.vendor = 0x1234;
    setup.id.product = 0x5678;
    setup.id.version = 1;
    ioctl(fd, UI_DEV_SETUP, &setup);

    if (ioctl(fd, UI_DEV_CREATE) < 0) {
        close(fd);
        return -1;
    }
    fprintf(stderr, "x11-input-proxy: created uinput touch device\n");
    return fd;
}

static void emit(int fd, unsigned short type, unsigned short code, int value)
{
    struct input_event ev = {0};
    ev.type = type;
    ev.code = code;
    ev.value = value;
    write(fd, &ev, sizeof(ev));
}

/* The kernel drops an EV_ABS report when its value is unchanged from
 * the axis's last known value - standard behavior for a plain ABS axis,
 * and this uinput device is never registered as a real input_mt
 * multitouch device, so ABS_MT_POSITION_X/Y get treated as plain ABS
 * axes and silently dropped whenever two consecutive touches (or two
 * SYN_REPORT position updates during a drag) land on the exact same
 * pixel - which then starves QtCarTouchDriver of any coordinates for
 * that touch. See docs/DEBUGGING_NOTES.md #18. Force a value change by
 * reporting a nudged position immediately before the real one; the
 * nudge is 1 unit so it's visually/functionally meaningless even if it
 * momentarily reaches a reader. */
static void emit_touch_position(int ui_fd, int tx, int ty)
{
    int nudge_x = tx > 0 ? tx - 1 : tx + 1;
    int nudge_y = ty > 0 ? ty - 1 : ty + 1;
    emit(ui_fd, EV_ABS, ABS_MT_POSITION_X, nudge_x);
    emit(ui_fd, EV_ABS, ABS_MT_POSITION_Y, nudge_y);
    emit(ui_fd, EV_ABS, ABS_MT_POSITION_X, tx);
    emit(ui_fd, EV_ABS, ABS_MT_POSITION_Y, ty);
}

int main(void)
{
    int in_fd, ui_fd;
    Display *dpy;
    struct input_event ev;
    int screen_w, screen_h;
    int cur_x = 0, cur_y = 0;
    int touch_active = 0, tracking_id = 0;
    int event_count = 0;
    int xtest_event, xtest_error, xtest_major, xtest_minor;

    fprintf(stderr, "x11-input-proxy: starting (pid %d)\n", getpid());

    in_fd = find_tablet_device();
    if (in_fd < 0) {
        fprintf(stderr, "x11-input-proxy: no tablet found\n");
        return 1;
    }

    /* Create uinput device for /dev/input/touch */
    ui_fd = create_uinput_device();
    if (ui_fd < 0)
        fprintf(stderr, "x11-input-proxy: warning: couldn't create uinput device\n");

    /* Connect to X11 */
    dpy = XOpenDisplay(":0");
    if (!dpy) {
        fprintf(stderr, "x11-input-proxy: waiting for X11...\n");
        int i;
        for (i = 0; i < 30 && !dpy; i++) {
            sleep(1);
            dpy = XOpenDisplay(":0");
        }
    }
    if (!dpy) {
        fprintf(stderr, "x11-input-proxy: cannot connect to X11\n");
        return 1;
    }

    screen_w = DisplayWidth(dpy, DefaultScreen(dpy));
    screen_h = DisplayHeight(dpy, DefaultScreen(dpy));
    fprintf(stderr, "x11-input-proxy: connected to X11 (%dx%d)\n", screen_w, screen_h);

    /* Verify XTest extension */
    if (!XTestQueryExtension(dpy, &xtest_event, &xtest_error, &xtest_major, &xtest_minor)) {
        fprintf(stderr, "x11-input-proxy: ERROR: XTest extension not available!\n");
        return 1;
    }
    fprintf(stderr, "x11-input-proxy: XTest %d.%d available\n", xtest_major, xtest_minor);

    fprintf(stderr, "x11-input-proxy: entering event loop\n");

    /* Event loop */
    while (read(in_fd, &ev, sizeof(ev)) == sizeof(ev)) {
        switch (ev.type) {
        case EV_ABS:
            if (ev.code == ABS_X) {
                cur_x = (int)((long)ev.value * screen_w / TABLET_MAX);
            } else if (ev.code == ABS_Y) {
                cur_y = (int)((long)ev.value * screen_h / TABLET_MAX);
            }
            break;

        case EV_KEY:
            if (ev.code == BTN_LEFT) {
                /* Log first few events */
                if (event_count < 5) {
                    fprintf(stderr, "x11-input-proxy: BTN_LEFT %s at (%d,%d)\n",
                            ev.value ? "press" : "release", cur_x, cur_y);
                    event_count++;
                }

                /* Inject X11 mouse button event */
                XTestFakeMotionEvent(dpy, DefaultScreen(dpy), cur_x, cur_y, 0);
                XTestFakeButtonEvent(dpy, 1, ev.value, 0);
                XFlush(dpy);

                /* Also emit on uinput for TouchDriver */
                if (ui_fd >= 0) {
                    int tx = cur_x * TOUCH_X_MAX / screen_w;
                    int ty = cur_y * TOUCH_Y_MAX / screen_h;
                    if (ev.value && !touch_active) {
                        touch_active = 1;
                        emit(ui_fd, EV_ABS, ABS_MT_SLOT, 0);
                        emit(ui_fd, EV_ABS, ABS_MT_TRACKING_ID, tracking_id++);
                        emit_touch_position(ui_fd, tx, ty);
                        emit(ui_fd, EV_KEY, BTN_TOUCH, 1);
                    } else if (!ev.value && touch_active) {
                        touch_active = 0;
                        emit(ui_fd, EV_ABS, ABS_MT_TRACKING_ID, -1);
                        emit(ui_fd, EV_KEY, BTN_TOUCH, 0);
                    }
                    emit(ui_fd, EV_SYN, SYN_REPORT, 0);
                }
            }
            break;

        case EV_SYN:
            if (ev.code == SYN_REPORT) {
                /* Send motion update to X11 */
                XTestFakeMotionEvent(dpy, DefaultScreen(dpy), cur_x, cur_y, 0);
                XFlush(dpy);

                /* Update uinput position if touching */
                if (ui_fd >= 0 && touch_active) {
                    int tx = cur_x * TOUCH_X_MAX / screen_w;
                    int ty = cur_y * TOUCH_Y_MAX / screen_h;
                    emit_touch_position(ui_fd, tx, ty);
                    emit(ui_fd, EV_SYN, SYN_REPORT, 0);
                }
            }
            break;
        }
    }

    fprintf(stderr, "x11-input-proxy: event loop ended (read returned %d)\n",
            (int)sizeof(ev));

    if (ui_fd >= 0) {
        ioctl(ui_fd, UI_DEV_DESTROY);
        close(ui_fd);
    }
    close(in_fd);
    XCloseDisplay(dpy);
    return 0;
}
