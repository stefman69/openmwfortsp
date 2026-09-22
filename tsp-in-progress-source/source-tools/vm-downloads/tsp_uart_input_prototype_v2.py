#!/usr/bin/env python3
"""
TSP UART INPUT PROTOTYPE
------------------------

Purpose:
  Diagnostic/prototype replacement for trimui_inputd_smart_pro on TrimUI Smart Pro.

Confirmed from the stock daemon:
  LEFT  source: /dev/ttyS4
  RIGHT source: /dev/ttyS3
  Serial: 19200 8N1
  Packet: 8 bytes
    [0]    0xFF
    [1]    unknown/reserved
    [2]    buttons
    [3:5]  signed 16-bit X, big-endian
    [5:7]  signed 16-bit Y, big-endian
    [7]    0xFE

This prototype intentionally does NOT reproduce clamp_scale().
It:
  1. Reads the UART packets directly.
  2. Calibrates each stick center from 50 valid packets.
  3. Subtracts the center.
  4. Emits raw-scale values (-32760..32760) through uinput.
  5. Logs RAW and OUTPUT values periodically.

It is axis-first: buttons are not emitted yet.
"""

import errno
import fcntl
import os
import select
import signal
import struct
import sys
import termios
import time

# Linux input/uinput constants.
# These ioctl values are taken directly from the stock daemon's setup_uinput()
# disassembly on the TSP kernel rather than assumed from a generic header.
EV_KEY = 0x01
EV_ABS = 0x03
SYN_REPORT = 0x00

ABS_X = 0
ABS_Y = 1
ABS_Z = 2
ABS_RZ = 5

BTN_A = 0x130
BUS_USB = 0x03

UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_ABSBIT = 0x40045567

# Newer uinput API present in the stock daemon.
UI_DEV_SETUP = 0x405c5503
UI_ABS_SETUP = 0x401c5504
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502

INPUT_EVENT = struct.Struct("llHHi")

UARTS = (
    ("/dev/ttyS4", "LEFT", ABS_X, ABS_Y),
    ("/dev/ttyS3", "RIGHT", ABS_Z, ABS_RZ),
)

UART_BAUD = termios.B19200
CALIBRATION_PACKETS = 50
AXIS_MIN = -32760
AXIS_MAX = 32760

RUNNING = True


def stop_handler(signum, frame):
    global RUNNING
    RUNNING = False


def configure_uart(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)

    attrs = termios.tcgetattr(fd)

    # 19200 8N1, matching setup_serial() in the stock daemon.
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = (
        (attrs[2] & ~(termios.CSIZE | termios.PARENB | termios.CSTOPB))
        | termios.CS8
        | termios.CREAD
        | termios.CLOCAL
    )
    attrs[3] = 0
    attrs[4] = UART_BAUD
    attrs[5] = UART_BAUD
    attrs[6][termios.VMIN] = 1
    attrs[6][termios.VTIME] = 0

    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIFLUSH)
    return fd


def ioctl_int(fd, request, value):
    # Use a mutable 4-byte buffer for _IOW integer ioctls, matching the
    # pointer semantics expected by the kernel.
    arg = bytearray(struct.pack("i", int(value)))
    fcntl.ioctl(fd, request, arg, True)


def ioctl_buf(fd, request, data):
    arg = bytearray(data)
    fcntl.ioctl(fd, request, arg, True)


def create_uinput():
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)

    # Mirror the stock daemon's ordering: establish EV_KEY first, then the
    # absolute-event capability. This is important on this vendor kernel.
    ioctl_int(fd, UI_SET_EVBIT, EV_KEY)
    ioctl_int(fd, UI_SET_KEYBIT, BTN_A)

    ioctl_int(fd, UI_SET_EVBIT, EV_ABS)

    # uinput_setup:
    #   struct input_id id;  (HHHH)
    #   char name[80];
    #   __u32 ff_effects_max;
    name = b"TSP UART Prototype Controller\0".ljust(80, b"\0")
    ident = struct.pack("HHHH", BUS_USB, 0x0000, 0x0001, 0x0100)
    setup = ident + name + struct.pack("I", 0)
    if len(setup) != 92:
        raise RuntimeError("Unexpected uinput_setup size: %d" % len(setup))

    ioctl_buf(fd, UI_DEV_SETUP, setup)

    # The stock daemon uses UI_ABS_SETUP with 28-byte structures:
    #   __u16 code;
    #   __u16 reserved;
    #   struct input_absinfo absinfo;
    #     value, minimum, maximum, fuzz, flat, resolution
    for axis in (ABS_X, ABS_Y, ABS_Z, ABS_RZ):
        abs_setup = struct.pack(
            "HHiiiiii",
            axis,
            0,
            0,          # value
            AXIS_MIN,   # minimum
            AXIS_MAX,   # maximum
            0,          # fuzz
            0,          # flat
            0,          # resolution
        )
        if len(abs_setup) != 28:
            raise RuntimeError("Unexpected uinput_abs_setup size")

        ioctl_buf(fd, UI_ABS_SETUP, abs_setup)

    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(0.25)
    return fd


def destroy_uinput(fd):
    if fd is None:
        return
    try:
        fcntl.ioctl(fd, UI_DEV_DESTROY)
    except OSError:
        pass
    try:
        os.close(fd)
    except OSError:
        pass


def emit(fd, event_type, code, value):
    os.write(fd, INPUT_EVENT.pack(0, 0, event_type, code, int(value)))


def emit_stick(fd, x_axis, y_axis, x, y):
    x = max(AXIS_MIN, min(AXIS_MAX, int(x)))
    y = max(AXIS_MIN, min(AXIS_MAX, int(y)))

    emit(fd, EV_ABS, x_axis, x)
    emit(fd, EV_ABS, y_axis, y)
    emit(fd, EV_SYN, SYN_REPORT, 0)


def decode_packets(buffer):
    packets = []

    while True:
        if len(buffer) < 8:
            break

        try:
            start = buffer.index(0xFF)
        except ValueError:
            buffer.clear()
            break

        if start:
            del buffer[:start]

        if len(buffer) < 8:
            break

        if buffer[7] != 0xFE:
            del buffer[0]
            continue

        packet = bytes(buffer[:8])
        del buffer[:8]
        packets.append(packet)

    return packets


def packet_axes(packet):
    x = int.from_bytes(packet[3:5], byteorder="big", signed=True)
    y = int.from_bytes(packet[5:7], byteorder="big", signed=True)
    buttons = packet[2]
    return x, y, buttons


def calibrate(ports):
    sums = {path: [0, 0] for path in ports}
    counts = {path: 0 for path in ports}
    buffers = {path: bytearray() for path in ports}
    fd_to_path = {fd: path for path, fd in ports.items()}

    print()
    print("========== CALIBRATION ==========")
    print("Keep both sticks centered.")
    print("Collecting %d valid packets per UART..." % CALIBRATION_PACKETS)
    print()

    deadline = time.monotonic() + 10.0

    while RUNNING and time.monotonic() < deadline:
        remaining = [fd for fd in ports.values() if counts[fd_to_path[fd]] < CALIBRATION_PACKETS]
        if not remaining:
            break

        ready, _, _ = select.select(remaining, [], [], 0.10)

        for fd in ready:
            path = fd_to_path[fd]

            try:
                data = os.read(fd, 512)
            except OSError as exc:
                if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    continue
                raise

            if data:
                buffers[path].extend(data)

            for packet in decode_packets(buffers[path]):
                if counts[path] >= CALIBRATION_PACKETS:
                    continue

                x, y, _buttons = packet_axes(packet)
                sums[path][0] += x
                sums[path][1] += y
                counts[path] += 1

    centers = {}

    for path, fd in ports.items():
        if counts[path] != CALIBRATION_PACKETS:
            raise RuntimeError(
                "%s calibration incomplete: %d/%d packets"
                % (path, counts[path], CALIBRATION_PACKETS)
            )

        centers[path] = (
            int(round(sums[path][0] / counts[path])),
            int(round(sums[path][1] / counts[path])),
        )

    for path, (cx, cy) in centers.items():
        print("%s center: X=%d Y=%d" % (path, cx, cy))

    print("=================================")
    print()
    return centers


def main():
    global RUNNING

    signal.signal(signal.SIGINT, stop_handler)
    signal.signal(signal.SIGTERM, stop_handler)

    if os.geteuid() != 0:
        print("ERROR: run as root.", file=sys.stderr)
        return 2

    print("==========================================")
    print(" TSP UART INPUT PROTOTYPE")
    print("==========================================")
    print("Direct UART -> uinput; stock input daemon must be stopped.")
    print("LEFT : /dev/ttyS4")
    print("RIGHT: /dev/ttyS3")
    print("UART : 19200 8N1")
    print("Packet: FF ?? buttons Xhi Xlo Yhi Ylo FE")
    print("Output: ABS_X/ABS_Y + ABS_Z/ABS_RZ")
    print("Stock clamp/deadzone: DISABLED; stock uinput ABI mirrored")
    print("Press Ctrl-C to stop.")
    print("==========================================")

    uart_fds = {}
    uinput_fd = None

    try:
        for path, name, _xa, _ya in UARTS:
            uart_fds[path] = configure_uart(path)

        centers = calibrate(uart_fds)

        uinput_fd = create_uinput()

        print("uinput device created.")
        print("Waiting for stick movement...")
        print()

        buffers = {path: bytearray() for path in uart_fds}
        fd_to_path = {fd: path for path, fd in uart_fds.items()}

        latest_raw = {path: (0, 0) for path in uart_fds}
        latest_out = {path: (0, 0) for path in uart_fds}

        peaks = {path: [0, 0] for path in uart_fds}

        last_report = time.monotonic()
        packet_count = {path: 0 for path in uart_fds}

        while RUNNING:
            ready, _, _ = select.select(list(uart_fds.values()), [], [], 0.05)

            for fd in ready:
                path = fd_to_path[fd]

                try:
                    data = os.read(fd, 512)
                except OSError as exc:
                    if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                        continue
                    raise

                if data:
                    buffers[path].extend(data)

                for packet in decode_packets(buffers[path]):
                    packet_count[path] += 1
                    raw_x, raw_y, _buttons = packet_axes(packet)
                    cx, cy = centers[path]

                    out_x = raw_x - cx
                    out_y = raw_y - cy

                    # Match the stock daemon's left-stick X orientation.
                    if path == "/dev/ttyS4":
                        out_x = -out_x

                    out_x = max(AXIS_MIN, min(AXIS_MAX, out_x))
                    out_y = max(AXIS_MIN, min(AXIS_MAX, out_y))

                    latest_raw[path] = (raw_x, raw_y)
                    latest_out[path] = (out_x, out_y)

                    peaks[path][0] = max(peaks[path][0], abs(out_x))
                    peaks[path][1] = max(peaks[path][1], abs(out_y))

                    if path == "/dev/ttyS4":
                        emit_stick(uinput_fd, ABS_X, ABS_Y, out_x, out_y)
                    else:
                        emit_stick(uinput_fd, ABS_Z, ABS_RZ, out_x, out_y)

            now = time.monotonic()

            if now - last_report >= 1.0:
                lx, ly = latest_out["/dev/ttyS4"]
                rx, ry = latest_out["/dev/ttyS3"]
                lrx, lry = latest_raw["/dev/ttyS4"]
                rrx, rry = latest_raw["/dev/ttyS3"]

                print(
                    "LEFT raw=(%6d,%6d) out=(%6d,%6d) peak=(%6d,%6d) packets=%d"
                    % (
                        lrx, lry, lx, ly,
                        peaks["/dev/ttyS4"][0], peaks["/dev/ttyS4"][1],
                        packet_count["/dev/ttyS4"],
                    ),
                    flush=True,
                )
                print(
                    "RIGHT raw=(%6d,%6d) out=(%6d,%6d) peak=(%6d,%6d) packets=%d"
                    % (
                        rrx, rry, rx, ry,
                        peaks["/dev/ttyS3"][0], peaks["/dev/ttyS3"][1],
                        packet_count["/dev/ttyS3"],
                    ),
                    flush=True,
                )

                last_report = now

    finally:
        if uinput_fd is not None:
            destroy_uinput(uinput_fd)

        for fd in uart_fds.values():
            try:
                os.close(fd)
            except OSError:
                pass

        print()
        print("Prototype stopped; uinput device destroyed.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
