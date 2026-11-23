#!/usr/bin/env python3
"""Builds resources/rime/english/hint.dict.yaml: English words offered while the
first letters are typed (wo → would, work; bec → because).

Usage: Scripts/generate-english-hints.py <wordfreq large_en.msgpack.gz> <output>

Rime's own completion lists the shortest words first (won, woe before would), so
instead each prefix gets its own entries: for every prefix of two letters or more,
the most frequent words that start with it, ranked by wordfreq. Only words already
in the English table (english/scowl and the letters-only entries of english/en_ext)
are offered, in that table's spelling, and only words used at least once per
million words (Zipf 3).

How many words a prefix gets follows how the input session places them
(InputSession+Engine mixedEnglishOrder, Windows PinyinSyllables.MixedEnglishOrder):
when the letters spell pinyin wholly (wo, men) or are only two letters (sh), Chinese
stays first and the words go to the end of the page, so 2; otherwise (wou, bec,
gith) the words come first, so 4. The pinyin syllables are read from
KeyiPinyinSyllables.swift so the two never disagree. The output is deterministic
for a given wordfreq file.
"""
import gzip
import pathlib
import re
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENGLISH = ROOT / "resources" / "rime" / "english"
SYLLABLES = ROOT / "Sources" / "KeyiIMEKit" / "KeyiPinyinSyllables.swift"

MIN_CENTIBELS = -600  # Zipf 3: once per million words
WEIGHT_OFFSET = 700  # weight = centibels + 700, so 100 (Zipf 3) to about 573 (the)
HINTS_AT_END = 2
HINTS_FIRST = 4


class MsgpackReader:
    """The subset of msgpack that wordfreq's data files use."""

    def __init__(self, data: bytes) -> None:
        self.data = data
        self.pos = 0

    def take(self, count: int) -> bytes:
        chunk = self.data[self.pos:self.pos + count]
        self.pos += count
        return chunk

    def number(self, fmt: str) -> int:
        size = struct.calcsize(fmt)
        return struct.unpack(fmt, self.take(size))[0]

    def read(self):
        byte = self.data[self.pos]
        self.pos += 1
        if byte <= 0x7F:
            return byte
        if byte >= 0xE0:
            return byte - 0x100
        if 0x80 <= byte <= 0x8F:
            return self.map(byte & 0x0F)
        if 0x90 <= byte <= 0x9F:
            return [self.read() for _ in range(byte & 0x0F)]
        if 0xA0 <= byte <= 0xBF:
            return self.take(byte & 0x1F).decode("utf-8")
        simple = {0xC0: None, 0xC2: False, 0xC3: True}
        if byte in simple:
            return simple[byte]
        numbers = {0xCC: ">B", 0xCD: ">H", 0xCE: ">I", 0xCF: ">Q",
                   0xD0: ">b", 0xD1: ">h", 0xD2: ">i", 0xD3: ">q"}
        if byte in numbers:
            return self.number(numbers[byte])
        strings = {0xD9: ">B", 0xDA: ">H", 0xDB: ">I"}
        if byte in strings:
            return self.take(self.number(strings[byte])).decode("utf-8")
        if byte in (0xDC, 0xDD):
            count = self.number(">H" if byte == 0xDC else ">I")
            return [self.read() for _ in range(count)]
        if byte in (0xDE, 0xDF):
            return self.map(self.number(">H" if byte == 0xDE else ">I"))
        raise ValueError(f"unsupported msgpack byte 0x{byte:02x} at {self.pos - 1}")

    def map(self, count: int) -> dict:
        result = {}
        for _ in range(count):
            key = self.read()
            result[key] = self.read()
        return result


def centibels(path: pathlib.Path) -> dict[str, int]:
    """word → frequency in centibels (0 is every word, -600 is once per million)."""
    reader = MsgpackReader(gzip.decompress(path.read_bytes()))
    header, *buckets = reader.read()
    if header.get("format") != "cB":
        raise SystemExit(f"unexpected wordfreq format: {header}")
    result: dict[str, int] = {}
    for index, words in enumerate(buckets):
        for word in words:
            result.setdefault(word, -index)
    return result


def table_words(path: pathlib.Path) -> list[str]:
    """Words of a Rime table, in file order (the part after the `...` line)."""
    words = []
    body = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line == "...":
            body = True
            continue
        if not body or not line or line.startswith("#"):
            continue
        words.append(line.split("\t", 1)[0])
    return words


def pinyin_syllables() -> set[str]:
    source = SYLLABLES.read_text(encoding="utf-8")
    block = source.split("static let all: Set<String> = [", 1)[1].split("]", 1)[0]
    syllables = set(re.findall(r'"([a-z]+)"', block))
    if len(syllables) != 414:
        raise SystemExit(f"expected 414 pinyin syllables, read {len(syllables)}")
    return syllables


def spells_wholly(letters: str, syllables: set[str]) -> bool:
    reachable = [False] * (len(letters) + 1)
    reachable[0] = True
    for start in range(len(letters)):
        if not reachable[start]:
            continue
        for end in range(start + 1, min(len(letters), start + 6) + 1):
            if letters[start:end] in syllables:
                reachable[end] = True
    return reachable[len(letters)]


def main() -> None:
    frequencies = centibels(pathlib.Path(sys.argv[1]))
    output = pathlib.Path(sys.argv[2])
    syllables = pinyin_syllables()

    # A common word keeps SCOWL's lower case (workers, not en_ext's Workers); a word only
    # en_ext has keeps its spelling (GitHub, JSON); then SCOWL's proper nouns (Monday).
    spelling: dict[str, str] = {}
    scowl = [word for word in table_words(ENGLISH / "scowl.dict.yaml") if re.fullmatch(r"[A-Za-z]{3,}", word)]
    en_ext = [word for word in table_words(ENGLISH / "en_ext.dict.yaml") if re.fullmatch(r"[A-Za-z]{3,}", word)]
    for word in [word for word in scowl if word.islower()] + en_ext + scowl:
        spelling.setdefault(word.lower(), word)

    by_prefix: dict[str, list[tuple[int, str]]] = {}
    for code, word in spelling.items():
        frequency = frequencies.get(code)
        if frequency is None or frequency < MIN_CENTIBELS:
            continue
        for length in range(2, len(code)):
            by_prefix.setdefault(code[:length], []).append((frequency, code))

    lines = [
        "# Rime dictionary",
        "# encoding: utf-8",
        "#",
        "# Generated by IME/Scripts/generate-english-hints.py. The words are those of",
        "# english/en_ext and english/scowl; which of them each prefix offers, and in what",
        "# order, comes from wordfreq word frequencies by Robyn Speer",
        "# (https://github.com/rspeer/wordfreq, data CC BY-SA 4.0), which include",
        "# SUBTLEX by Marc Brysbaert et al. (freely available data), OpenSubtitles,",
        "# Google Books Ngrams, Wikipedia, ParaCrawl and the Leeds Internet Corpus; see",
        "# LICENSE.wordfreq.md in this directory. This file is licensed under",
        "# CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/).",
        "",
        "---",
        "name: hint",
        'version: "1.0"',
        "sort: by_weight",
        "...",
    ]
    entries = 0
    for prefix in sorted(by_prefix):
        first = len(prefix) >= 3 and not spells_wholly(prefix, syllables)
        ranked = sorted(by_prefix[prefix], key=lambda item: (-item[0], item[1]))
        for frequency, code in ranked[: HINTS_FIRST if first else HINTS_AT_END]:
            lines.append(f"{spelling[code]}\t{prefix}\t{frequency + WEIGHT_OFFSET}")
            entries += 1
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"prefixes={len(by_prefix)} entries={entries}")


if __name__ == "__main__":
    main()
