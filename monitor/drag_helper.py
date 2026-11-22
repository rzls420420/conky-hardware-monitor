#!/usr/bin/env python3
"""Interactive left-click X11 drag controller for ConkyDashboard with workarea clamping."""

import ctypes
import fcntl
import os
import sys
import time

POS_PATH = os.path.join(os.path.expanduser("~"), ".config", "conky", "position.txt")
LOCK_PATH = "/tmp/conky-drag.lock"
TARGET_CLASS = b"ConkyDashboard"
BUTTON1_MASK = 1 << 8  # X11 Button1Mask = 0x100


class XClassHint(ctypes.Structure):
    _fields_ = [("res_name", ctypes.c_void_p), ("res_class", ctypes.c_void_p)]


def setup_x11():
    x11 = ctypes.CDLL("libX11.so.6")

    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p

    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    x11.XCloseDisplay.restype = ctypes.c_int

    x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    x11.XDefaultRootWindow.restype = ctypes.c_ulong

    x11.XDefaultScreen.argtypes = [ctypes.c_void_p]
    x11.XDefaultScreen.restype = ctypes.c_int

    x11.XDisplayWidth.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x11.XDisplayWidth.restype = ctypes.c_int

    x11.XDisplayHeight.argtypes = [ctypes.c_void_p, ctypes.c_int]
    x11.XDisplayHeight.restype = ctypes.c_int

    x11.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x11.XInternAtom.restype = ctypes.c_ulong

    x11.XGetWindowProperty.argtypes = [
        ctypes.c_void_p,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_long,
        ctypes.c_long,
        ctypes.c_int,
        ctypes.c_ulong,
        ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.c_void_p),
    ]
    x11.XGetWindowProperty.restype = ctypes.c_int

    x11.XFree.argtypes = [ctypes.c_void_p]
    x11.XFree.restype = ctypes.c_int

    x11.XGetClassHint.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(XClassHint)]
    x11.XGetClassHint.restype = ctypes.c_int

    x11.XGetGeometry.argtypes = [
        ctypes.c_void_p,
        ctypes.c_ulong,
        ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_uint),
        ctypes.POINTER(ctypes.c_uint),
        ctypes.POINTER(ctypes.c_uint),
        ctypes.POINTER(ctypes.c_uint),
    ]
    x11.XGetGeometry.restype = ctypes.c_int

    x11.XTranslateCoordinates.argtypes = [
        ctypes.c_void_p,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_ulong),
    ]
    x11.XTranslateCoordinates.restype = ctypes.c_int

    x11.XQueryPointer.argtypes = [
        ctypes.c_void_p,
        ctypes.c_ulong,
        ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_int),
        ctypes.POINTER(ctypes.c_uint),
    ]
    x11.XQueryPointer.restype = ctypes.c_int

    x11.XQueryTree.argtypes = [
        ctypes.c_void_p,
        ctypes.c_ulong,
        ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.c_ulong),
        ctypes.POINTER(ctypes.c_void_p),
        ctypes.POINTER(ctypes.c_uint),
    ]
    x11.XQueryTree.restype = ctypes.c_int

    x11.XMoveWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int]
    x11.XMoveWindow.restype = ctypes.c_int

    x11.XFlush.argtypes = [ctypes.c_void_p]
    x11.XFlush.restype = ctypes.c_int

    return x11


def get_ulongs_prop(x11, dpy, win, atom_name):
    atom = x11.XInternAtom(dpy, atom_name, 0)
    actual_type = ctypes.c_ulong()
    actual_fmt = ctypes.c_int()
    nitems = ctypes.c_ulong()
    bytes_after = ctypes.c_ulong()
    prop = ctypes.c_void_p()
    rc = x11.XGetWindowProperty(
        dpy,
        win,
        atom,
        0,
        4096,
        0,
        0,  # AnyPropertyType
        ctypes.byref(actual_type),
        ctypes.byref(actual_fmt),
        ctypes.byref(nitems),
        ctypes.byref(bytes_after),
        ctypes.byref(prop),
    )
    if rc != 0 or not prop.value or actual_fmt.value != 32:
        if prop.value:
            x11.XFree(prop)
        return []
    arr = ctypes.cast(prop.value, ctypes.POINTER(ctypes.c_ulong))
    res = [arr[i] for i in range(nitems.value)]
    x11.XFree(prop)
    return res


def match_class(x11, dpy, win):
    hint = XClassHint()
    if x11.XGetClassHint(dpy, win, ctypes.byref(hint)) == 0:
        return False
    matched = False
    if hint.res_class:
        cls_val = ctypes.string_at(hint.res_class)
        matched = cls_val == TARGET_CLASS
        x11.XFree(hint.res_class)
    if hint.res_name:
        x11.XFree(hint.res_name)
    return matched


def find_conky_window(x11, dpy, root):
    for w in get_ulongs_prop(x11, dpy, root, b"_NET_CLIENT_LIST"):
        if match_class(x11, dpy, w):
            return w

    # Fallback: walk root's direct children / subtrees
    r_ret = ctypes.c_ulong()
    p_ret = ctypes.c_ulong()
    children_ptr = ctypes.c_void_p()
    nchildren = ctypes.c_uint()
    if x11.XQueryTree(
        dpy, root, ctypes.byref(r_ret), ctypes.byref(p_ret), ctypes.byref(children_ptr), ctypes.byref(nchildren)
    ):
        if children_ptr.value:
            arr = ctypes.cast(children_ptr.value, ctypes.POINTER(ctypes.c_ulong))
            for i in range(nchildren.value):
                w = arr[i]
                if match_class(x11, dpy, w):
                    x11.XFree(children_ptr)
                    return w
            x11.XFree(children_ptr)
    return None


def get_workarea(x11, dpy, root):
    wa = get_ulongs_prop(x11, dpy, root, b"_NET_WORKAREA")
    if len(wa) >= 4 and wa[2] > 0 and wa[3] > 0:
        return int(wa[0]), int(wa[1]), int(wa[2]), int(wa[3])
    scr = x11.XDefaultScreen(dpy)
    return 0, 0, x11.XDisplayWidth(dpy, scr), x11.XDisplayHeight(dpy, scr)


def query_pointer(x11, dpy, root):
    r_ret = ctypes.c_ulong()
    c_ret = ctypes.c_ulong()
    rx = ctypes.c_int()
    ry = ctypes.c_int()
    wx = ctypes.c_int()
    wy = ctypes.c_int()
    mask = ctypes.c_uint()
    x11.XQueryPointer(
        dpy,
        root,
        ctypes.byref(r_ret),
        ctypes.byref(c_ret),
        ctypes.byref(rx),
        ctypes.byref(ry),
        ctypes.byref(wx),
        ctypes.byref(wy),
        ctypes.byref(mask),
    )
    return rx.value, ry.value, mask.value


def save_position(x, y):
    os.makedirs(os.path.dirname(POS_PATH), exist_ok=True)
    tmp = f"{POS_PATH}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(f"{x} {y}\n")
    os.replace(tmp, POS_PATH)


def clamp(v, lo, hi):
    if v < lo:
        return lo
    if v > hi:
        return hi
    return v


def main():
    lock_fd = open(LOCK_PATH, "w", encoding="utf-8")
    try:
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock_fd.close()
        return

    clamp_only = "--clamp-only" in sys.argv
    start_px = None
    start_py = None
    if not clamp_only and len(sys.argv) >= 3:
        try:
            start_px = int(float(sys.argv[1]))
            start_py = int(float(sys.argv[2]))
        except ValueError:
            pass

    x11 = setup_x11()
    disp_env = os.environ.get("DISPLAY", ":0").encode("utf-8")
    dpy = x11.XOpenDisplay(disp_env)
    if not dpy:
        lock_fd.close()
        return

    try:
        root = x11.XDefaultRootWindow(dpy)
        win = find_conky_window(x11, dpy, root)
        if not win:
            return

        g_root = ctypes.c_ulong()
        gx = ctypes.c_int()
        gy = ctypes.c_int()
        gw = ctypes.c_uint()
        gh = ctypes.c_uint()
        gbw = ctypes.c_uint()
        gdepth = ctypes.c_uint()
        if x11.XGetGeometry(
            dpy,
            win,
            ctypes.byref(g_root),
            ctypes.byref(gx),
            ctypes.byref(gy),
            ctypes.byref(gw),
            ctypes.byref(gh),
            ctypes.byref(gbw),
            ctypes.byref(gdepth),
        ) == 0:
            return

        win_x0 = ctypes.c_int()
        win_y0 = ctypes.c_int()
        child = ctypes.c_ulong()
        if x11.XTranslateCoordinates(
            dpy, win, root, 0, 0, ctypes.byref(win_x0), ctypes.byref(win_y0), ctypes.byref(child)
        ) == 0:
            return

        work_x, work_y, work_w, work_h = get_workarea(x11, dpy, root)
        min_x = work_x
        min_y = work_y
        max_x = max(work_x, work_x + work_w - int(gw.value))
        max_y = max(work_y, work_y + work_h - int(gh.value))

        x0 = win_x0.value
        y0 = win_y0.value

        if clamp_only:
            cx = clamp(x0, min_x, max_x)
            cy = clamp(y0, min_y, max_y)
            if (cx, cy) != (x0, y0):
                x11.XMoveWindow(dpy, win, cx, cy)
                x11.XFlush(dpy)
                save_position(cx, cy)
            return

        px_now, py_now, mask = query_pointer(x11, dpy, root)
        if (mask & BUTTON1_MASK) == 0:
            return

        px0 = start_px if start_px is not None else px_now
        py0 = start_py if start_py is not None else py_now

        last_x = x0
        last_y = y0
        moved = False

        while (mask & BUTTON1_MASK) != 0:
            nx = clamp(x0 + (px_now - px0), min_x, max_x)
            ny = clamp(y0 + (py_now - py0), min_y, max_y)
            if nx != last_x or ny != last_y:
                x11.XMoveWindow(dpy, win, nx, ny)
                x11.XFlush(dpy)
                last_x = nx
                last_y = ny
                moved = True
            time.sleep(0.008)
            px_now, py_now, mask = query_pointer(x11, dpy, root)

        if moved:
            save_position(last_x, last_y)
    finally:
        x11.XCloseDisplay(dpy)
        lock_fd.close()


if __name__ == "__main__":
    main()
