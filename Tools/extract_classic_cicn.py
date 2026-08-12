#!/usr/bin/env python3
"""Extract selected classic Mac OS 'cicn' resources as RGBA PNG files.

The PlayerPRO source archive keeps its original artwork in the resource fork of
Files/General.rsrc.  DeRez exposes that data portably, and this small converter
preserves the original indexed pixels and one-bit mask without redrawing them.
"""

from __future__ import annotations

import argparse
import binascii
import re
import struct
import subprocess
import zlib
from pathlib import Path


def be16(data: bytes, offset: int) -> int:
    return struct.unpack_from(">H", data, offset)[0]


def chunk(kind: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFFFFFF)
    )


def write_png(path: Path, width: int, height: int, rgba: bytes) -> None:
    rows = bytearray()
    stride = width * 4
    for row in range(height):
        rows.append(0)
        rows.extend(rgba[row * stride : (row + 1) * stride])
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(rows), 9))
        + chunk(b"IEND", b"")
    )


def decode_cicn(data: bytes) -> tuple[int, int, bytes]:
    pixel_row_bytes = be16(data, 4) & 0x3FFF
    top, left, bottom, right = struct.unpack_from(">hhhh", data, 6)
    width, height = right - left, bottom - top
    pixel_size = be16(data, 32)
    if pixel_size not in (1, 2, 4, 8):
        raise ValueError(f"unsupported indexed pixel size {pixel_size}")

    mask_row_bytes = be16(data, 54) & 0x3FFF
    mask_top, mask_left, mask_bottom, mask_right = struct.unpack_from(">hhhh", data, 56)
    mono_row_bytes = be16(data, 68) & 0x3FFF
    mono_top, mono_left, mono_bottom, mono_right = struct.unpack_from(">hhhh", data, 70)
    if (mask_bottom - mask_top, mask_right - mask_left) != (height, width):
        raise ValueError("mask dimensions do not match icon")
    if (mono_bottom - mono_top, mono_right - mono_left) != (height, width):
        raise ValueError("monochrome dimensions do not match icon")

    offset = 82  # PixMap + mask BitMap + mono BitMap + icon-data Handle
    mask = data[offset : offset + mask_row_bytes * height]
    offset += mask_row_bytes * height + mono_row_bytes * height

    offset += 4  # color-table seed
    offset += 2  # color-table flags
    last_color = be16(data, offset)
    offset += 2
    palette: dict[int, tuple[int, int, int]] = {}
    for _ in range(last_color + 1):
        index, red, green, blue = struct.unpack_from(">HHHH", data, offset)
        offset += 8
        palette[index] = (red >> 8, green >> 8, blue >> 8)

    pixels = data[offset : offset + pixel_row_bytes * height]
    rgba = bytearray(width * height * 4)
    per_byte = 8 // pixel_size
    value_mask = (1 << pixel_size) - 1
    for y in range(height):
        for x in range(width):
            packed = pixels[y * pixel_row_bytes + x // per_byte]
            shift = 8 - pixel_size * ((x % per_byte) + 1)
            index = (packed >> shift) & value_mask
            red, green, blue = palette.get(index, (0, 0, 0))
            opaque = mask[y * mask_row_bytes + x // 8] & (0x80 >> (x % 8))
            destination = (y * width + x) * 4
            rgba[destination : destination + 4] = bytes(
                (red, green, blue, 255 if opaque else 0)
            )
    return width, height, bytes(rgba)


def resource_data(source: str, resource_id: int, resource_type: str = "cicn") -> bytes:
    output = subprocess.check_output(["DeRez", source, "-only", resource_type]).decode(
        "mac_roman", errors="replace"
    )
    match = re.search(
        rf"data '{resource_type}' \({resource_id}(?:,[^)]*)?\) \{{(.*?)\n\}};",
        output,
        re.DOTALL,
    )
    if match is None:
        raise ValueError(f"{resource_type} {resource_id} was not found")
    encoded = "".join(re.findall(r'\$"([0-9A-Fa-f ]+)"', match.group(1))).replace(" ", "")
    return bytes.fromhex(encoded)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    args.destination.mkdir(parents=True, exist_ok=True)

    names = {
        400: "classic-staff-rest-16.png",
        401: "classic-staff-rest-8.png",
        402: "classic-staff-rest-4.png",
        403: "classic-staff-rest-2.png",
        404: "classic-staff-rest-1.png",
        500: "classic-staff-note-16.png",
        501: "classic-staff-note-8.png",
        502: "classic-staff-note-4.png",
        503: "classic-staff-note-2.png",
        504: "classic-staff-note-1.png",
        600: "classic-staff-note-inverted-16.png",
        601: "classic-staff-note-inverted-8.png",
        602: "classic-staff-note-inverted-4.png",
        603: "classic-staff-note-inverted-2.png",
        604: "classic-staff-note-inverted-1.png",
        700: "classic-staff-natural.png",
        701: "classic-staff-flat.png",
        702: "classic-staff-sharp.png",
        800: "classic-staff-dot.png",
    }
    for resource_id, name in names.items():
        width, height, rgba = decode_cicn(resource_data(args.source, resource_id))
        write_png(args.destination / name, width, height, rgba)



if __name__ == "__main__":
    main()
