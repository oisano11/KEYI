#!/usr/bin/env python3
"""Read and validate Windows PE file/product version resources."""

from __future__ import annotations

import argparse
import json
import re
import struct
import sys
from pathlib import Path


class VersionResourceError(ValueError):
    pass


def read_u16(data: bytes, offset: int) -> int:
    if offset < 0 or offset + 2 > len(data):
        raise VersionResourceError("PE 数据截断")
    return struct.unpack_from("<H", data, offset)[0]


def read_u32(data: bytes, offset: int) -> int:
    if offset < 0 or offset + 4 > len(data):
        raise VersionResourceError("PE 数据截断")
    return struct.unpack_from("<I", data, offset)[0]


def align4(value: int) -> int:
    return (value + 3) & ~3


def read_utf16_key(data: bytes, offset: int, limit: int) -> tuple[str, int]:
    units: list[int] = []
    while offset + 2 <= limit:
        unit = read_u16(data, offset)
        offset += 2
        if unit == 0:
            return bytes(struct.pack(f"<{len(units)}H", *units)).decode(
                "utf-16-le"
            ), offset
        units.append(unit)
    raise VersionResourceError("版本资源键未终止")


def rva_to_offset(
    rva: int, sections: list[tuple[int, int, int, int]]
) -> int:
    for virtual_address, virtual_size, raw_offset, raw_size in sections:
        extent = max(virtual_size, raw_size)
        if virtual_address <= rva < virtual_address + extent:
            delta = rva - virtual_address
            if delta >= raw_size:
                raise VersionResourceError("版本资源未映射到文件数据")
            return raw_offset + delta
    raise VersionResourceError(f"无法映射 PE RVA 0x{rva:x}")


def locate_version_resource(data: bytes) -> bytes:
    if data[:2] != b"MZ":
        raise VersionResourceError("文件不是 PE 可执行文件")
    pe_offset = read_u32(data, 0x3C)
    if data[pe_offset : pe_offset + 4] != b"PE\0\0":
        raise VersionResourceError("PE 签名无效")

    coff_offset = pe_offset + 4
    section_count = read_u16(data, coff_offset + 2)
    optional_size = read_u16(data, coff_offset + 16)
    optional_offset = coff_offset + 20
    optional_magic = read_u16(data, optional_offset)
    if optional_magic == 0x20B:
        data_directory_offset = optional_offset + 112
    elif optional_magic == 0x10B:
        data_directory_offset = optional_offset + 96
    else:
        raise VersionResourceError("不支持的 PE Optional Header")

    resource_rva = read_u32(data, data_directory_offset + 16)
    if resource_rva == 0:
        raise VersionResourceError("PE 不含资源目录")

    section_offset = optional_offset + optional_size
    sections: list[tuple[int, int, int, int]] = []
    for index in range(section_count):
        offset = section_offset + index * 40
        sections.append(
            (
                read_u32(data, offset + 12),
                read_u32(data, offset + 8),
                read_u32(data, offset + 20),
                read_u32(data, offset + 16),
            )
        )

    resource_base = rva_to_offset(resource_rva, sections)

    def directory_entries(relative_offset: int) -> list[tuple[int, int]]:
        directory_offset = resource_base + relative_offset
        named_count = read_u16(data, directory_offset + 12)
        id_count = read_u16(data, directory_offset + 14)
        entries = []
        for index in range(named_count + id_count):
            entry_offset = directory_offset + 16 + index * 8
            entries.append(
                (read_u32(data, entry_offset), read_u32(data, entry_offset + 4))
            )
        return entries

    root_version_entry = next(
        (
            target
            for name, target in directory_entries(0)
            if name & 0x80000000 == 0 and name & 0xFFFF == 16
        ),
        None,
    )
    if root_version_entry is None:
        raise VersionResourceError("PE 不含 RT_VERSION 资源")

    target = root_version_entry
    for _ in range(4):
        if target & 0x80000000 == 0:
            data_entry_offset = resource_base + target
            value_rva = read_u32(data, data_entry_offset)
            value_size = read_u32(data, data_entry_offset + 4)
            value_offset = rva_to_offset(value_rva, sections)
            if value_offset + value_size > len(data):
                raise VersionResourceError("版本资源数据截断")
            return data[value_offset : value_offset + value_size]
        children = directory_entries(target & 0x7FFFFFFF)
        if not children:
            raise VersionResourceError("版本资源目录为空")
        target = children[0][1]
    raise VersionResourceError("版本资源目录层级无效")


def parse_version_resource(resource: bytes) -> dict[str, str]:
    strings: dict[str, str] = {}

    def parse_block(offset: int, limit: int) -> int:
        if offset + 6 > limit:
            return limit
        length = read_u16(resource, offset)
        if length == 0:
            return limit
        end = offset + length
        if end > limit:
            raise VersionResourceError("版本资源块越界")
        value_length = read_u16(resource, offset + 2)
        value_type = read_u16(resource, offset + 4)
        key, key_end = read_utf16_key(resource, offset + 6, end)
        value_offset = align4(key_end)
        value_size = value_length * 2 if value_type == 1 else value_length
        value_end = min(value_offset + value_size, end)

        if key in {"FileVersion", "ProductVersion"} and value_length:
            strings[key] = resource[value_offset:value_end].decode(
                "utf-16-le", errors="strict"
            ).rstrip("\0")

        child_offset = align4(value_end)
        while child_offset + 6 <= end:
            child_length = read_u16(resource, child_offset)
            if child_length == 0:
                break
            next_offset = parse_block(child_offset, end)
            if next_offset <= child_offset:
                raise VersionResourceError("版本资源子块长度无效")
            child_offset = align4(next_offset)
        return end

    root_length = read_u16(resource, 0)
    root_value_length = read_u16(resource, 2)
    _, root_key_end = read_utf16_key(resource, 6, min(root_length, len(resource)))
    root_value_offset = align4(root_key_end)
    if root_value_length < 52 or root_value_offset + 52 > len(resource):
        raise VersionResourceError("VS_FIXEDFILEINFO 缺失")
    fixed = struct.unpack_from("<13I", resource, root_value_offset)
    if fixed[0] != 0xFEEF04BD:
        raise VersionResourceError("VS_FIXEDFILEINFO 签名无效")

    def format_version(ms: int, ls: int) -> str:
        return f"{ms >> 16}.{ms & 0xFFFF}.{ls >> 16}.{ls & 0xFFFF}"

    parse_block(0, min(root_length, len(resource)))
    return {
        "file_version": format_version(fixed[2], fixed[3]),
        "product_version_fixed": format_version(fixed[4], fixed[5]),
        "file_version_string": strings.get("FileVersion", ""),
        "product_version": strings.get("ProductVersion", ""),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="读取并校验 Windows PE 文件版本与产品版本"
    )
    parser.add_argument("path", type=Path)
    parser.add_argument("--expected-version", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.expected_version):
        print("错误：expected-version 必须为三段数字版本号", file=sys.stderr)
        return 2

    try:
        version = parse_version_resource(
            locate_version_resource(args.path.read_bytes())
        )
    except (OSError, UnicodeDecodeError, VersionResourceError) as error:
        print(f"错误：无法读取 {args.path} 的版本资源：{error}", file=sys.stderr)
        return 2

    expected_file_version = f"{args.expected_version}.0"
    product_version = version["product_version"]
    product_matches = product_version == args.expected_version or (
        product_version.startswith(args.expected_version)
        and len(product_version) > len(args.expected_version)
        and product_version[len(args.expected_version)] in "+-."
    )
    checks = {
        "file_version_matches": version["file_version"] == expected_file_version,
        "product_version_matches": product_matches,
    }
    result = {
        "path": str(args.path),
        "expected_version": args.expected_version,
        **version,
        **checks,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if not all(checks.values()):
        print("错误：PE 文件版本或产品版本与目标版本不一致", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
