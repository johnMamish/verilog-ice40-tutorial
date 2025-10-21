#!/bin/python3

from PIL import Image
import numpy as np

import argparse
import os
import serial
import sys


def netpbm_to_rgb444_packed(fobj, gamma=2.2):
    """
    Read a NetPBM file from an opened file-like object,
    crop/pad to 64x64, apply gamma correction, and convert
    to packed RGB444 byte array where red is in the least-
    significant nibble of each 12-bit word.

    Packing: 2 pixels (2x12bit) → 3 bytes
      byte0 = word0[7:0]
      byte1 = word0[11:8] | (word1[3:0] << 4)
      byte2 = word1[11:4]
    """

    img = Image.open(fobj).convert("RGB")
    w, h = img.size

    # --- crop / pad to 64x64 ---
    start_x = max(0, (w - 64) // 2)
    start_y = max(0, (h - 64) // 2)
    end_x = min(start_x + 64, w)
    end_y = min(start_y + 64, h)
    cropped = img.crop((start_x, start_y, end_x, end_y))

    out = Image.new("RGB", (64, 64), (0, 0, 0))
    paste_x = (64 - cropped.width) // 2
    paste_y = (64 - cropped.height) // 2
    out.paste(cropped, (paste_x, paste_y))

    arr = np.array(out, dtype=np.float32)  # shape (64,64,3), floats

    # --- normalize to 0–1 ---
    arr /= 255.0

    # --- apply gamma correction ---
    arr = np.power(arr, 1.0 / gamma)

    # --- quantize to 4 bits (0–15) ---
    quant = np.clip(np.round(arr * 15.0), 0, 15).astype(np.uint16)

    r = quant[..., 0]
    g = quant[..., 1]
    b = quant[..., 2]

    # --- pack into 12-bit words: [B(4)][G(4)][R(4)] ---
    words = (r << 8) | (g << 4) | b
    words = words.flatten()

    packed = bytearray()
    for i in range(0, len(words), 2):
        w0 = int(words[i])
        w1 = int(words[i+1]) if i+1 < len(words) else 0
        packed.append(w0 & 0xFF)
        packed.append(((w0 >> 8) & 0x0F) | ((w1 & 0x0F) << 4))
        packed.append((w1 >> 4) & 0xFF)
    return bytes(packed)


def main():
    parser = argparse.ArgumentParser(description="Send data over a serial port.")
    parser.add_argument("--port", required=True, help="Serial port (e.g., /dev/ttyUSB0 or COM3)")
    parser.add_argument("--baud", type=int, default=2000000, help="Baud rate (default: 2000000)")
    parser.add_argument("--src", type=str, default=None, help="")
    args = parser.parse_args()

    try:
        ser = serial.Serial(port=args.port, baudrate=args.baud, timeout=1)
    except serial.SerialException as e:
        print(f"Error opening serial port {args.port}: {e}", file=sys.stderr)
        sys.exit(1)


    # list of bytearrays that can be transmitted to the screen
    frames = []
    if (args.src is not None):
        # Read images in order from the source directory
        for fname in sorted(os.listdir(args.src)):
            path = os.path.join(args.src, fname)
            if not os.path.isfile(path):
                continue
            with open(path, "rb") as f:
                frames.append(netpbm_to_rgb444_packed(f))

    else:
        # Just fill with a gradient.
        b = bytes()
        for i in range (int(64 * 64 / 2)):
            v = 2 * i
            r1 = 0#v % 16
            g1 = 0#(v >> 4) % 16
            b1 = (v >> 8) % 16
            v += 1
            r2 = 0#v % 16
            g2 = 0#(v >> 4) % 16
            b2 = (v >> 8) % 16
            packed = ((b1 << 0) | (g1 << 4) | (r1 << 8) | (b2 << 12) | (g2 << 16) | (r2 << 20))
            b += packed.to_bytes(3, byteorder="little")
        frames.append(b)

    j = 0
    framecnt = 0
    while (True):
        # Wait for a byte
        received = ser.read(1)
        ser.reset_input_buffer()
        if (received):
            print(f"Got a byte {received}. sending frame {framecnt:7d} / {len(frames):7d}.")
            ser.write(frames[framecnt])
            framecnt = (framecnt + 1) % len(frames)
            print(f"done transmitting next frame")

if __name__ == "__main__":
    main()
