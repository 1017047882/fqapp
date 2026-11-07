#!/usr/bin/env python3
"""@brief Fail closed on incompatible embedded Mach-O files before IPA packaging.

@note Reads a completed, immutable archive; callers must finish Xcode before checking.
This checks deployment metadata, not runtime behavior or all imported symbols.
"""
import argparse
import json
import pathlib
import plistlib
import struct


def version(value):
    parts = tuple(map(int, str(value).split(".")))
    return (parts + (0, 0))[:3]


def check_macho(data, maximum):
    """Validate arm64 device slices, including FAT wrappers, and return their minimum OS."""
    fat_formats = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
                   b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
    if data[:4] in fat_formats:
        if len(data) < 8:
            raise ValueError("truncated FAT header")
        endian, wide = fat_formats[data[:4]]
        count = struct.unpack_from(endian + "I", data, 4)[0]
        entry_size = 32 if wide else 20
        table_end = 8 + count * entry_size
        if not count or table_end > len(data):
            raise ValueError("invalid FAT slice table")
        requirements = []
        ranges = []
        for index in range(count):
            entry = struct.unpack_from(endian + ("IIQQII" if wide else "IIIII"), data, 8 + index * entry_size)
            cpu, _, offset, size = entry[:4]
            if cpu != 0x0100000C:
                raise ValueError("expected arm64 architecture in every FAT slice")
            if offset < table_end or size < 32 or offset + size > len(data):
                raise ValueError("invalid FAT slice bounds")
            if any(offset < end and start < offset + size for start, end in ranges):
                raise ValueError("overlapping FAT slices")
            ranges.append((offset, offset + size))
            image = data[offset:offset + size]
            if image[:4] != b"\xcf\xfa\xed\xfe":
                raise ValueError("expected thin arm64 Mach-O inside FAT slice")
            requirements.append(check_macho(image, maximum))
        return max(requirements)
    if len(data) < 32 or data[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("expected thin arm64 Mach-O")
    _, cpu, _, _, count, size, _, _ = struct.unpack_from("<8I", data)
    if cpu != 0x0100000C:
        raise ValueError("expected arm64 architecture")
    end = 32 + size
    if end > len(data):
        raise ValueError("truncated Mach-O commands")
    offset = 32
    minimum = None
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError("truncated command header")
        command, length = struct.unpack_from("<2I", data, offset)
        if length < 8 or offset + length > end:
            raise ValueError("invalid command length")
        if command == 0x32:
            if length < 24:
                raise ValueError("truncated build version")
            platform, encoded = struct.unpack_from("<2I", data, offset + 8)
            if platform != 2:
                raise ValueError(f"expected iOS device platform, got {platform}")
        elif command == 0x25:
            if length < 16:
                raise ValueError("truncated deployment command")
            encoded = struct.unpack_from("<I", data, offset + 8)[0]
        else:
            offset += length
            continue
        found = (encoded >> 16, (encoded >> 8) & 255, encoded & 255)
        minimum = max(minimum or found, found)
        offset += length
    if minimum is None:
        raise ValueError("missing deployment command")
    if minimum > maximum:
        raise ValueError(f"binary minimum {minimum} exceeds app minimum {maximum}")
    return minimum


def check_app(app):
    """Require Flutter runtime images and inspect every embedded executable image."""
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    minimum = version(info["MinimumOSVersion"])
    if minimum != (15, 0, 0) or 1 not in info.get("UIDeviceFamily", []):
        raise ValueError("expected iPhone support with MinimumOSVersion 15.0")
    required = [info["CFBundleExecutable"], "Frameworks/App.framework/App",
                "Frameworks/Flutter.framework/Flutter"]
    for relative in required:
        if not (app / relative).exists():
            raise ValueError(f"missing runtime: {relative}")
    images = []
    magic = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe",
             b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
             b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
    for path in sorted(app.rglob("*")):
        if not path.is_file():
            continue
        with path.open("rb") as stream:
            header = stream.read(4)
        if header not in magic:
            continue
        try:
            needed = check_macho(path.read_bytes(), minimum)
        except ValueError as error:
            raise ValueError(f"{path.relative_to(app)}: {error}") from error
        images.append({"path": path.relative_to(app).as_posix(), "minimum": ".".join(map(str, needed))})
    if not set(required).issubset({image["path"] for image in images}):
        raise ValueError("app or required Flutter framework is not a validated Mach-O")
    return {"minimumOS": "15.0", "architecture": "arm64", "device": "iPhone", "images": images}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=pathlib.Path)
    args = parser.parse_args()
    try:
        print(json.dumps(check_app(args.app), indent=2))
    except (ValueError, KeyError, OSError, struct.error) as error:
        parser.exit(1, f"iOS 15 compatibility check failed: {error}\n")
