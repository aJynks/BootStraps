#!/usr/bin/env python3
"""
trackerextract_script.py - Extract WAV samples from tracker modules.

Supports: .mod (ProTracker, 15/31 sample, plus .nst/.wow/.m15 variants)
          .xm  (FastTracker 2)
          .s3m (Scream Tracker 3)
          .it  (Impulse Tracker, including IT214/IT215 compressed samples)

All output is signed 16-bit PCM WAV.

Default naming:      {inst:02d}-{smp:02d}_[{source.ext}].wav
With --names:        {inst:02d}-{smp:02d}_[{source.ext}]_{name}.wav

A log file "_{source.ext}.txt" is always written alongside the WAVs with the
full, uncapped naming detail for every sample slot.

Standard library only - no third-party dependencies.
"""

import sys

if sys.version_info < (3, 7):
    sys.exit("This script requires Python 3.7 or newer.")

# Dependency check (stdlib only, but verify the modules are importable).
_missing = []
for _m in ('wave', 'struct', 'argparse', 'glob', 're'):
    try:
        __import__(_m)
    except ImportError:
        _missing.append(_m)
if _missing:
    sys.exit("Missing standard library modules: %s\n"
             "Your Python installation is incomplete; reinstall Python."
             % ', '.join(_missing))

import os
import re
import glob
import wave
import struct
import argparse
from pathlib import Path


# MOD variants first - all handled by the MOD parser.
MOD_EXTENSIONS = {'.mod', '.nst', '.wow', '.m15', '.mod15'}
SUPPORTED_EXTENSIONS = MOD_EXTENSIONS | {'.xm', '.s3m', '.it'}

PLACEHOLDER_NAMES = {'unknown', 'untitled', 'unnamed', 'none'}
UNNAMED = 'unnamed'

# Windows MAX_PATH is 260 including the terminating NUL, so 259 usable.
MAX_PATH = 259
SUBFOLDER_CAP = 80      # module subfolder name
FIELD_FLOOR = 4         # a name field shorter than this is meaningless


# ===========================================================================
# Name handling
# ===========================================================================

def decode_field(raw):
    """Decode a fixed-width tracker name field to text.

    Tracker name fields are CP437 and NUL-padded, but some writers pad with
    spaces or leave trailing garbage after the NUL.
    """
    if not raw:
        return ''
    raw = raw.split(b'\x00', 1)[0]
    text = raw.decode('cp437', errors='replace')
    text = ''.join(c for c in text if c >= ' ')
    return text.strip()


def is_placeholder(name):
    """True if the field is a tracker placeholder rather than a real name."""
    return name.strip().lower() in PLACEHOLDER_NAMES


def strip_pseudo_ext(name):
    """Remove a trailing DOS-style pseudo extension.

    CHURCH.PAT   -> CHURCH
    Thincrsh.Lev -> Thincrsh
    CHRIS58A.IT  -> CHRIS58A
    Completed on 9/26/95 -> unchanged (".95" is not extension-shaped)
    """
    return re.sub(r'\.[A-Za-z][A-Za-z0-9]{0,3}$', '', name)


def sanitize(name):
    """Replace unsafe characters, collapsing " / " to a single dash."""
    name = re.sub(r'\s*/\s*', '-', name)
    name = re.sub(r'[\s\\:*?"<>|]', '_', name)
    name = re.sub(r'_{2,}', '_', name)
    name = re.sub(r'-{2,}', '-', name)
    return name.strip('_-. ')


def clean_field(raw):
    """Sanitize one tracker name field; '' if unusable."""
    if not raw or is_placeholder(raw):
        return ''
    return sanitize(strip_pseudo_ext(raw))


def cap_subfolder(source_filename):
    """Sanitized module subfolder name, capped so it leaves path budget."""
    return sanitize(source_filename)[:SUBFOLDER_CAP]


def plain_output_name(inst, smp, source_filename):
    """The short form used without --names, and as the final fallback."""
    return "%02d-%02d_[%s].wav" % (inst, smp, sanitize(source_filename))


def build_rich_name(inst, smp, inst_name, smp_name, source_filename,
                    dos_name, budget):
    """Build the --names filename, shrinking fields to fit budget bytes.

    Layout:
      {inst}-{smp}_{inst_name}--{smp_name}_[{source.ext}]-{dos_name}.wav

    Missing fields become "unnamed", except when none of the three name
    fields is usable, in which case the caller falls back to the plain form.
    Fields are shrunk longest-first so one runaway field is cut rather than
    everything being chopped equally.
    """
    fields = {
        'inst_name': inst_name or UNNAMED,
        'smp_name': smp_name or UNNAMED,
        'source': sanitize(source_filename),
        'dos_name': dos_name or UNNAMED,
    }

    def assemble(f):
        return ("%02d-%02d_%s--%s_[%s]-%s.wav"
                % (inst, smp, f['inst_name'], f['smp_name'],
                   f['source'], f['dos_name']))

    name = assemble(fields)
    if len(name) <= budget:
        return name

    # Shrink the longest field one character at a time until it fits.
    order = ['inst_name', 'smp_name', 'source', 'dos_name']
    while len(name) > budget:
        longest = max(order, key=lambda k: len(fields[k]))
        if len(fields[longest]) <= FIELD_FLOOR:
            break
        fields[longest] = fields[longest][:-1].rstrip('_-. ') or fields[longest][:-1]
        name = assemble(fields)

    return name


def fit_filename(inst, smp, inst_name, smp_name, source_filename,
                 dos_name, use_names, budget):
    """Return a filename that fits within budget, or None if nothing does.

    Falls back progressively:
      rich form -> plain form -> bare index form -> None
    """
    if use_names and (inst_name or smp_name or dos_name):
        name = build_rich_name(inst, smp, inst_name, smp_name,
                               source_filename, dos_name, budget)
        if len(name) <= budget:
            return name

    plain = plain_output_name(inst, smp, source_filename)
    if len(plain) <= budget:
        return plain

    bare = "%02d-%02d.wav" % (inst, smp)
    if len(bare) <= budget:
        return bare

    return None


# Kept for the log, which records the untruncated chosen name.
def pick_name(dos_name, smp_name, inst_name):
    """First usable field in the agreed fallback order, uncapped."""
    for candidate in (dos_name, smp_name, inst_name):
        cleaned = clean_field(candidate)
        if cleaned:
            return cleaned
    return ''


# ===========================================================================
# PCM helpers
# ===========================================================================

def write_wav(path, pcm16, channels, framerate):
    with wave.open(str(path), 'wb') as wf:
        wf.setnchannels(channels)
        wf.setsampwidth(2)
        wf.setframerate(max(1, int(framerate)))
        wf.writeframes(pcm16)


def s8_to_s16(data):
    out = bytearray(len(data) * 2)
    for i, b in enumerate(data):
        struct.pack_into('<h', out, i * 2, (b - 256 if b >= 128 else b) * 256)
    return bytes(out)


def u8_to_s16(data):
    out = bytearray(len(data) * 2)
    for i, b in enumerate(data):
        struct.pack_into('<h', out, i * 2, (b - 128) * 256)
    return bytes(out)


def u16le_to_s16(data):
    n = len(data) // 2
    vals = struct.unpack('<%dH' % n, data[:n * 2])
    return struct.pack('<%dh' % n, *[v - 32768 for v in vals])


def s16be_to_s16le(data):
    n = len(data) // 2
    vals = struct.unpack('>%dh' % n, data[:n * 2])
    return struct.pack('<%dh' % n, *vals)


def interleave_stereo(left, right, width):
    """Interleave two planar channel buffers into frame-interleaved data."""
    n = min(len(left), len(right)) // width
    out = bytearray(n * width * 2)
    for i in range(n):
        o = i * width * 2
        s = i * width
        out[o:o + width] = left[s:s + width]
        out[o + width:o + width * 2] = right[s:s + width]
    return bytes(out)


# ===========================================================================
# Sample record
# ===========================================================================

class Sample:
    """One sample slot. pcm is None in dry-run mode or when skipped."""

    def __init__(self, inst, smp, pcm=None, channels=1, framerate=8363,
                 frames=0, bits=8, comp='', global_smp=None,
                 dos_name='', smp_name='', inst_name='', skipped=''):
        self.inst = inst
        self.smp = smp
        self.pcm = pcm
        self.channels = channels
        self.framerate = framerate
        self.frames = frames
        self.bits = bits
        self.comp = comp
        self.global_smp = global_smp
        self.dos_name = dos_name
        self.smp_name = smp_name
        self.inst_name = inst_name
        self.skipped = skipped
        self.final_name = None

    def display_name(self):
        """First usable field, uncapped - what the log records."""
        return pick_name(self.dos_name, self.smp_name, self.inst_name)

    def clean_fields(self):
        """Sanitized (inst_name, smp_name, dos_name), '' where unusable."""
        return (clean_field(self.inst_name),
                clean_field(self.smp_name),
                clean_field(self.dos_name))

    def filename(self, source_name, use_names, budget=MAX_PATH):
        inst_n, smp_n, dos_n = self.clean_fields()
        return fit_filename(self.inst, self.smp, inst_n, smp_n,
                            source_name, dos_n, use_names, budget)

    def audio_line(self):
        ch = 'stereo' if self.channels == 2 else 'mono'
        extra = (', ' + self.comp) if self.comp else ''
        return ("%d frames, %d-bit, %s, %d Hz%s"
                % (self.frames, self.bits, ch, self.framerate, extra))


# ===========================================================================
# IT214 / IT215 sample decompression
# ===========================================================================

class BitReader:
    """LSB-first bit reader over a byte buffer."""

    __slots__ = ('data', 'pos', 'buf', 'cnt')

    def __init__(self, data):
        self.data = data
        self.pos = 0
        self.buf = 0
        self.cnt = 0

    def read(self, n):
        while self.cnt < n:
            if self.pos >= len(self.data):
                return None
            self.buf |= self.data[self.pos] << self.cnt
            self.pos += 1
            self.cnt += 8
        v = self.buf & ((1 << n) - 1)
        self.buf >>= n
        self.cnt -= n
        return v


def it_decompress8(data, offset, num_samples, it215):
    """Decompress IT214/IT215 8-bit sample data.

    Returns (signed 8-bit PCM bytes, bytes consumed from the file).
    """
    out = bytearray()
    pos = offset
    total = len(data)

    while len(out) < num_samples:
        if pos + 2 > total:
            break
        block_len = struct.unpack_from('<H', data, pos)[0]
        pos += 2
        if pos + block_len > total:
            block_len = total - pos
        block = data[pos:pos + block_len]
        pos += block_len

        br = BitReader(block)
        want = min(0x8000, num_samples - len(out))
        width = 9
        d1 = d2 = 0
        written = 0

        while written < want:
            if width == 0 or width > 9:
                break
            value = br.read(width)
            if value is None:
                break

            if width < 7:
                if value == (1 << (width - 1)):
                    nw = br.read(3)
                    if nw is None:
                        break
                    nw += 1
                    width = nw if nw < width else nw + 1
                    continue
            elif width < 9:
                border = (0xFF >> (9 - width)) - 4
                if border < value <= border + 8:
                    value -= border
                    width = value if value < width else value + 1
                    continue
            elif width == 9:
                if value & 0x100:
                    width = (value + 1) & 0xFF
                    continue
            else:
                break

            if width < 8:
                shift = 8 - width
                t = (value << shift) & 0xFF
                if t >= 128:
                    t -= 256
                v = t >> shift
            else:
                v = value - 256 if value >= 128 else value

            d1 = (d1 + v) & 0xFF
            d1s = d1 - 256 if d1 >= 128 else d1
            d2 = (d2 + d1s) & 0xFF

            out.append(d2 if it215 else d1)
            written += 1

        if written == 0:
            break
        if written < want:
            out.extend(b'\x00' * (want - written))

    if len(out) < num_samples:
        out.extend(b'\x00' * (num_samples - len(out)))
    return bytes(out[:num_samples]), pos - offset


def it_decompress16(data, offset, num_samples, it215):
    """Decompress IT214/IT215 16-bit sample data.

    Returns (signed 16-bit LE PCM bytes, bytes consumed from the file).
    """
    out = []
    pos = offset
    total = len(data)

    while len(out) < num_samples:
        if pos + 2 > total:
            break
        block_len = struct.unpack_from('<H', data, pos)[0]
        pos += 2
        if pos + block_len > total:
            block_len = total - pos
        block = data[pos:pos + block_len]
        pos += block_len

        br = BitReader(block)
        want = min(0x4000, num_samples - len(out))
        width = 17
        d1 = d2 = 0
        written = 0

        while written < want:
            if width == 0 or width > 17:
                break
            value = br.read(width)
            if value is None:
                break

            if width < 7:
                if value == (1 << (width - 1)):
                    nw = br.read(4)
                    if nw is None:
                        break
                    nw += 1
                    width = nw if nw < width else nw + 1
                    continue
            elif width < 17:
                border = (0xFFFF >> (17 - width)) - 8
                if border < value <= border + 16:
                    value -= border
                    width = value if value < width else value + 1
                    continue
            elif width == 17:
                if value & 0x10000:
                    width = (value + 1) & 0xFF
                    continue
            else:
                break

            if width < 16:
                shift = 16 - width
                t = (value << shift) & 0xFFFF
                if t >= 32768:
                    t -= 65536
                v = t >> shift
            else:
                v = value - 65536 if value >= 32768 else value

            d1 = (d1 + v) & 0xFFFF
            d1s = d1 - 65536 if d1 >= 32768 else d1
            d2 = (d2 + d1s) & 0xFFFF

            r = d2 if it215 else d1
            out.append(r - 65536 if r >= 32768 else r)
            written += 1

        if written == 0:
            break
        if written < want:
            out.extend([0] * (want - written))

    if len(out) < num_samples:
        out.extend([0] * (num_samples - len(out)))
    out = out[:num_samples]
    return struct.pack('<%dh' % len(out), *out), pos - offset


# ===========================================================================
# .MOD parser
# ===========================================================================
#
# 31-sample layout:
#   0x000  20    title
#   0x014  31x30 sample headers (name 22, length/2 BE, finetune, vol, loop)
#   0x3B6  1     song length
#   0x3B8  128   order table
#   0x438  4     format tag
#   0x43C  ...   pattern data, then sample data
#
# 15-sample layout has no tag; header ends at 0x258.

MOD_FINETUNE_RATES = [
    8363, 8413, 8463, 8529, 8581, 8651, 8723, 8757,
    7895, 7941, 7985, 8046, 8107, 8169, 8232, 8280,
]

MOD_TAG_CHANNELS = {
    b'M.K.': 4, b'M!K!': 4, b'M&K!': 4, b'N.T.': 4, b'NSMS': 4,
    b'FLT4': 4, b'FLT8': 8, b'OCTA': 8, b'OKTA': 8, b'CD81': 8,
}


def mod_channels_from_tag(tag):
    """Channel count for a MOD format tag, or None if unrecognised."""
    if tag in MOD_TAG_CHANNELS:
        return MOD_TAG_CHANNELS[tag]
    try:
        s = tag.decode('ascii')
    except UnicodeDecodeError:
        return None
    if len(s) == 4:
        if s[1:] == 'CHN' and s[0].isdigit():
            return int(s[0])
        if s[2:] == 'CH' and s[:2].isdigit():
            return int(s[:2])
        if s[:3] == 'TDZ' and s[3].isdigit():
            return int(s[3])
    return None


def parse_mod(data, source_name, decode):
    samples = []

    if len(data) < 600:
        print("  [SKIP] too short to be a valid MOD")
        return samples

    num_slots = 15
    num_channels = 4
    header_end = 600

    if len(data) >= 1084:
        ch = mod_channels_from_tag(data[1080:1084])
        if ch:
            num_slots = 31
            num_channels = ch
            header_end = 1084

    headers = []
    for i in range(num_slots):
        off = 20 + i * 30
        headers.append({
            'name': decode_field(data[off:off + 22]),
            'length': struct.unpack_from('>H', data, off + 22)[0] * 2,
            'finetune': data[off + 24] & 0x0F,
        })

    order_base = header_end - 4 - 128 if num_slots == 31 else 600 - 128
    song_len = data[order_base - 2]
    orders = data[order_base:order_base + 128]
    scan = orders[:song_len] if 0 < song_len <= 128 else orders
    num_patterns = (max(scan) + 1) if scan else 1

    total_sample_bytes = sum(h['length'] for h in headers)

    # Mod's Grave (.wow) writes an M.K. tag but stores 8 channels.
    # Pick whichever channel count makes the file size add up.
    if num_slots == 31 and data[1080:1084] in (b'M.K.', b'M!K!'):
        fit4 = header_end + num_patterns * 4 * 64 * 4 + total_sample_bytes
        fit8 = header_end + num_patterns * 8 * 64 * 4 + total_sample_bytes
        if abs(len(data) - fit8) < abs(len(data) - fit4):
            num_channels = 8

    sample_start = header_end + num_patterns * num_channels * 64 * 4

    if sample_start + total_sample_bytes > len(data):
        alt = len(data) - total_sample_bytes
        if alt >= header_end:
            sample_start = alt

    pos = sample_start
    for i, h in enumerate(headers):
        length = h['length']
        if length <= 2:
            pos += length
            continue

        if pos >= len(data):
            samples.append(Sample(i + 1, 1, global_smp=i + 1,
                                  smp_name=h['name'],
                                  skipped='data pointer past end of file'))
            continue

        avail = min(length, len(data) - pos)
        raw = data[pos:pos + avail]
        pos += length

        note = ('truncated (%d of %d bytes)' % (avail, length)) if avail < length else ''

        samples.append(Sample(
            i + 1, 1,
            pcm=s8_to_s16(raw) if decode else None,
            channels=1,
            framerate=MOD_FINETUNE_RATES[h['finetune']],
            frames=avail, bits=8, comp=note,
            global_smp=i + 1,
            smp_name=h['name'],
        ))

    return samples


# ===========================================================================
# .XM parser
# ===========================================================================
#
# Song header:  0x3C header size, 0x46 numPatterns, 0x48 numInstruments
# Pattern:      +0 header length, +7 packed size
# Instrument:   +0 size, +4 name(22), +27 numSamples, +29 sample header size
# Sample hdr:   +0 length(bytes), +13 finetune, +14 flags, +16 rel note,
#               +18 name(22)


def parse_xm(data, source_name, decode):
    samples = []

    if len(data) < 80 or data[0:17] != b'Extended Module: ':
        print("  [SKIP] XM magic not found")
        return samples

    header_size = struct.unpack_from('<I', data, 0x3C)[0]
    num_patterns = struct.unpack_from('<H', data, 0x46)[0]
    num_instruments = struct.unpack_from('<H', data, 0x48)[0]

    pos = 0x3C + header_size

    # Pattern data sits between the song header and the instruments.
    for p in range(num_patterns):
        if pos + 9 > len(data):
            print("  [WARN] pattern table truncated at pattern %d" % (p + 1))
            return samples
        pat_hdr_len = struct.unpack_from('<I', data, pos)[0] or 9
        packed_size = struct.unpack_from('<H', data, pos + 7)[0]
        pos += pat_hdr_len + packed_size

    global_counter = 0

    for inst_idx in range(num_instruments):
        if pos + 29 > len(data):
            break

        inst_size = struct.unpack_from('<I', data, pos)[0]
        if inst_size < 29:
            inst_size = 29
        inst_name = decode_field(data[pos + 4:pos + 26])
        num_smp = struct.unpack_from('<H', data, pos + 27)[0]

        if num_smp == 0:
            pos += inst_size
            continue

        smp_hdr_size = struct.unpack_from('<I', data, pos + 29)[0]
        if smp_hdr_size < 40:
            smp_hdr_size = 40

        hdr_start = pos + inst_size
        hdrs = []
        for s in range(num_smp):
            hp = hdr_start + s * smp_hdr_size
            if hp + 40 > len(data):
                break
            flags = data[hp + 14]
            hdrs.append({
                'length': struct.unpack_from('<I', data, hp)[0],
                'finetune': struct.unpack_from('<b', data, hp + 13)[0],
                'is_16bit': bool(flags & 0x10),
                'is_stereo': bool(flags & 0x20),
                'rel_note': struct.unpack_from('<b', data, hp + 16)[0],
                'name': decode_field(data[hp + 18:hp + 40]),
            })

        data_pos = hdr_start + num_smp * smp_hdr_size

        for s_idx, h in enumerate(hdrs):
            global_counter += 1
            length = h['length']
            if length == 0:
                continue

            if data_pos >= len(data):
                samples.append(Sample(inst_idx + 1, s_idx + 1,
                                      global_smp=global_counter,
                                      smp_name=h['name'], inst_name=inst_name,
                                      skipped='data pointer past end of file'))
                continue

            avail = min(length, len(data) - data_pos)
            raw = data[data_pos:data_pos + avail]
            data_pos += length

            channels = 2 if h['is_stereo'] else 1

            if decode:
                if h['is_16bit']:
                    n = len(raw) // 2
                    deltas = struct.unpack('<%dh' % n, raw[:n * 2])
                    vals = []
                    run = 0
                    for d in deltas:
                        run = (run + d) & 0xFFFF
                        vals.append(run - 65536 if run >= 32768 else run)
                    pcm = struct.pack('<%dh' % len(vals), *vals)
                    frames = len(vals)
                else:
                    vals = []
                    run = 0
                    for b in raw:
                        run = (run + (b - 256 if b >= 128 else b)) & 0xFF
                        vals.append(run)
                    pcm = s8_to_s16(bytes(vals))
                    frames = len(vals)
                frames //= channels
            else:
                pcm = None
                frames = (avail // 2 if h['is_16bit'] else avail) // channels

            semitones = h['rel_note'] + h['finetune'] / 128.0
            rate = max(1000, min(192000, int(8363 * (2.0 ** (semitones / 12.0)))))

            samples.append(Sample(
                inst_idx + 1, s_idx + 1,
                pcm=pcm, channels=channels, framerate=rate,
                frames=frames, bits=16 if h['is_16bit'] else 8,
                comp='truncated' if avail < length else '',
                global_smp=global_counter,
                smp_name=h['name'], inst_name=inst_name,
            ))

        pos = data_pos

    return samples


# ===========================================================================
# .S3M parser
# ===========================================================================
#
# File header:  0x20 OrdNum, 0x22 InsNum, 0x2A Ffi (1=signed, 2=unsigned)
# Sample hdr:   0x00 type, 0x01 DOS name(12), 0x0D/0x0E MemSeg,
#               0x10 length, 0x1E pack, 0x1F flags, 0x20 C2Spd,
#               0x30 name(28)


def parse_s3m(data, source_name, decode):
    samples = []

    if len(data) < 96 or data[44:48] != b'SCRM':
        print("  [SKIP] S3M magic not found")
        return samples

    num_orders = struct.unpack_from('<H', data, 0x20)[0]
    num_inst = struct.unpack_from('<H', data, 0x22)[0]
    signed_samples = (struct.unpack_from('<H', data, 0x2A)[0] == 1)

    base = 96 + num_orders

    for i in range(num_inst):
        pp = base + i * 2
        if pp + 2 > len(data):
            break
        off = struct.unpack_from('<H', data, pp)[0] * 16
        if off == 0 or off + 80 > len(data):
            continue
        if data[off] != 1:
            continue

        dos_name = decode_field(data[off + 1:off + 13])
        smp_name = decode_field(data[off + 0x30:off + 0x4C])
        length = struct.unpack_from('<I', data, off + 0x10)[0]
        pack = data[off + 0x1E]
        flags = data[off + 0x1F]
        c2spd = struct.unpack_from('<I', data, off + 0x20)[0] or 8363

        if length == 0:
            continue

        if pack != 0:
            samples.append(Sample(i + 1, 1, global_smp=i + 1,
                                  dos_name=dos_name, smp_name=smp_name,
                                  skipped='ADPCM packed sample (pack=%d)' % pack))
            continue

        is_stereo = bool(flags & 0x02)
        is_16bit = bool(flags & 0x04)
        width = 2 if is_16bit else 1
        channels = 2 if is_stereo else 1

        seg = (data[off + 0x0D] << 16) | struct.unpack_from('<H', data, off + 0x0E)[0]
        sdata = seg * 16

        chan_bytes = length * width
        need = chan_bytes * channels
        note = ''

        if sdata == 0 or sdata >= len(data):
            samples.append(Sample(i + 1, 1, global_smp=i + 1,
                                  dos_name=dos_name, smp_name=smp_name,
                                  skipped='data pointer past end of file'))
            continue

        if sdata + need > len(data):
            note = 'truncated'
            need = len(data) - sdata
            chan_bytes = need // channels

        if decode:
            if is_stereo:
                left = data[sdata:sdata + chan_bytes]
                right = data[sdata + chan_bytes:sdata + chan_bytes * 2]
                raw = interleave_stereo(left, right, width)
            else:
                raw = data[sdata:sdata + chan_bytes]

            if is_16bit:
                pcm = raw if signed_samples else u16le_to_s16(raw)
            else:
                pcm = s8_to_s16(raw) if signed_samples else u8_to_s16(raw)
        else:
            pcm = None

        samples.append(Sample(
            i + 1, 1,
            pcm=pcm, channels=channels, framerate=c2spd,
            frames=chan_bytes // width, bits=16 if is_16bit else 8,
            comp=note, global_smp=i + 1,
            dos_name=dos_name, smp_name=smp_name,
        ))

    return samples


# ===========================================================================
# .IT parser
# ===========================================================================
#
# File header:  0x20 OrdNum, 0x22 InsNum, 0x24 SmpNum, 0x2A Cmwt
# IMPI:         0x04 DOS name(12), 0x20 name(26), 0x40 keyboard table
# IMPS:         0x04 DOS name(12), 0x12 Flg, 0x14 name(26), 0x2E Cvt,
#               0x30 length, 0x3C C5Speed, 0x48 sample pointer
#
# For compressed samples Cvt bit 2 selects IT215 (double integration);
# the tracker version alone is not sufficient.


def parse_it(data, source_name, decode):
    samples = []

    if len(data) < 192 or data[0:4] != b'IMPM':
        print("  [SKIP] IT magic not found")
        return samples

    num_orders = struct.unpack_from('<H', data, 0x20)[0]
    num_inst = struct.unpack_from('<H', data, 0x22)[0]
    num_smp = struct.unpack_from('<H', data, 0x24)[0]
    cmwt = struct.unpack_from('<H', data, 0x2A)[0]

    inst_base = 192 + num_orders
    smp_base = inst_base + num_inst * 4

    # --- instrument -> sample map, in keyboard order of first appearance ---
    inst_names = {}
    owners = {}

    for i in range(num_inst):
        pp = inst_base + i * 4
        if pp + 4 > len(data):
            break
        off = struct.unpack_from('<I', data, pp)[0]
        if off == 0 or off + 0x40 > len(data):
            continue
        if data[off:off + 4] != b'IMPI':
            continue

        inst_names[i + 1] = decode_field(data[off + 0x20:off + 0x3A])

        order = []
        seen = set()
        for n in range(120):
            ep = off + 0x40 + n * 2
            if ep + 2 > len(data):
                break
            ref = data[ep + 1]
            if ref and ref not in seen:
                seen.add(ref)
                order.append(ref)

        for local_ord, gs in enumerate(order, 1):
            owners.setdefault(gs, []).append((i + 1, local_ord))

    cache = {}

    def decode_sample(gs):
        """Decode global sample gs once; returns an info dict or None."""
        if gs in cache:
            return cache[gs]

        pp = smp_base + (gs - 1) * 4
        if gs < 1 or gs > num_smp or pp + 4 > len(data):
            return None
        off = struct.unpack_from('<I', data, pp)[0]
        if off == 0 or off + 80 > len(data):
            return None
        if data[off:off + 4] != b'IMPS':
            return None

        info = {
            'dos_name': decode_field(data[off + 0x04:off + 0x10]),
            'smp_name': decode_field(data[off + 0x14:off + 0x2E]),
        }

        flg = data[off + 0x12]
        cvt = data[off + 0x2E]
        length = struct.unpack_from('<I', data, off + 0x30)[0]
        c5 = struct.unpack_from('<I', data, off + 0x3C)[0] or 8363
        sptr = struct.unpack_from('<I', data, off + 0x48)[0]

        has_sample = bool(flg & 0x01)
        is_16bit = bool(flg & 0x02)
        is_stereo = bool(flg & 0x04)
        is_comp = bool(flg & 0x08)

        if not has_sample or length == 0:
            cache[gs] = None
            return None

        info.update({'frames': length, 'rate': c5,
                     'bits': 16 if is_16bit else 8,
                     'channels': 2 if is_stereo else 1,
                     'comp': '', 'skipped': '', 'pcm': None})

        if sptr == 0 or sptr >= len(data):
            info['skipped'] = 'data pointer past end of file'
            cache[gs] = info
            return info

        # Cvt bit 2 marks IT215 double-integration for compressed samples.
        it215 = is_comp and cmwt >= 0x0215 and bool(cvt & 0x04)
        if is_comp:
            info['comp'] = 'IT215' if it215 else 'IT214'

        width = 2 if is_16bit else 1
        channels = info['channels']

        if decode:
            if is_comp:
                dec = it_decompress16 if is_16bit else it_decompress8
                left, used = dec(data, sptr, length, it215)
                if is_stereo:
                    right, _ = dec(data, sptr + used, length, it215)
                    raw = interleave_stereo(left, right, width)
                else:
                    raw = left
                info['pcm'] = raw if is_16bit else s8_to_s16(raw)
            else:
                chan_bytes = length * width
                need = chan_bytes * channels
                if sptr + need > len(data):
                    info['comp'] = ((info['comp'] + ' ') if info['comp'] else '') + 'truncated'
                    need = len(data) - sptr
                    chan_bytes = need // channels
                    info['frames'] = chan_bytes // width

                if is_stereo:
                    left = data[sptr:sptr + chan_bytes]
                    right = data[sptr + chan_bytes:sptr + chan_bytes * 2]
                    raw = interleave_stereo(left, right, width)
                else:
                    raw = data[sptr:sptr + chan_bytes]

                is_signed = bool(cvt & 0x01)
                if is_16bit:
                    if cvt & 0x02:
                        raw = s16be_to_s16le(raw)
                    info['pcm'] = raw if is_signed else u16le_to_s16(raw)
                else:
                    info['pcm'] = s8_to_s16(raw) if is_signed else u8_to_s16(raw)

        cache[gs] = info
        return info

    # Samples referenced by an instrument
    written = set()
    for gs in sorted(owners):
        info = decode_sample(gs)
        if info is None:
            continue
        for inst_num, local_ord in owners[gs]:
            samples.append(Sample(
                inst_num, local_ord,
                pcm=info['pcm'], channels=info['channels'],
                framerate=info['rate'], frames=info['frames'],
                bits=info['bits'], comp=info['comp'],
                global_smp=gs,
                dos_name=info['dos_name'], smp_name=info['smp_name'],
                inst_name=inst_names.get(inst_num, ''),
                skipped=info['skipped'],
            ))
        written.add(gs)

    # Samples not referenced by any instrument keep flat numbering
    for gs in range(1, num_smp + 1):
        if gs in written:
            continue
        info = decode_sample(gs)
        if info is None:
            continue
        samples.append(Sample(
            gs, 1,
            pcm=info['pcm'], channels=info['channels'],
            framerate=info['rate'], frames=info['frames'],
            bits=info['bits'], comp=info['comp'],
            global_smp=gs,
            dos_name=info['dos_name'], smp_name=info['smp_name'],
            skipped=info['skipped'],
        ))

    return samples


# ===========================================================================
# Format detection
# ===========================================================================

PARSERS = {'mod': parse_mod, 'xm': parse_xm, 's3m': parse_s3m, 'it': parse_it}

FORMAT_LABEL = {'mod': 'MOD', 'xm': 'XM', 's3m': 'S3M', 'it': 'IT'}


def detect_format(data, path):
    if len(data) >= 4 and data[0:4] == b'IMPM':
        return 'it'
    if len(data) >= 48 and data[44:48] == b'SCRM':
        return 's3m'
    if len(data) >= 17 and data[0:17] == b'Extended Module: ':
        return 'xm'
    if len(data) >= 1084 and mod_channels_from_tag(data[1080:1084]):
        return 'mod'
    ext = path.suffix.lower()
    if ext in MOD_EXTENSIONS:
        return 'mod'
    if ext in SUPPORTED_EXTENSIONS:
        return ext.lstrip('.')
    return None


# ===========================================================================
# Log file
# ===========================================================================

def write_log(log_path, source_name, fmt, found, use_names, written_count):
    """Write the full, uncapped naming detail for every sample slot."""
    lines = []
    lines.append("# %s v%s" % (TOOL, VERSION))
    lines.append("# source      : %s" % source_name)
    lines.append("# format      : %s" % FORMAT_LABEL.get(fmt, fmt))

    comps = sorted({s.comp for s in found if s.comp in ('IT214', 'IT215')})
    if comps:
        lines.append("# compression : %s" % ', '.join(comps))

    lines.append("# slots       : %d" % len(found))
    lines.append("# written     : %d" % written_count)
    lines.append("# --names     : %s" % ('yes' if use_names else 'no'))
    lines.append("")

    for s in found:
        lines.append("[%02d-%02d]" % (s.inst, s.smp))
        if s.skipped:
            lines.append("  skipped     : %s" % s.skipped)
        else:
            lines.append("  file        : %s"
                         % (s.final_name or s.filename(source_name, use_names)))
        if s.global_smp is not None:
            lines.append("  global_smp  : %d" % s.global_smp)
        if s.dos_name:
            lines.append("  dos_name    : %s" % s.dos_name)
        if s.smp_name:
            lines.append("  smp_name    : %s" % s.smp_name)
        if s.inst_name:
            lines.append("  inst_name   : %s" % s.inst_name)
        chosen = s.display_name()
        if chosen:
            lines.append("  chosen_name : %s" % chosen)
        if not s.skipped:
            lines.append("  audio       : %s" % s.audio_line())
        lines.append("")

    log_path.write_text('\n'.join(lines), encoding='utf-8')


# ===========================================================================
# Driver
# ===========================================================================

def extract_file(path, output_dir, dry_run, use_names):
    """Process one module. Returns (written, skipped_files)."""
    print("\n-> %s" % path.name)

    try:
        data = path.read_bytes()
    except OSError as e:
        print("  [SKIP] cannot read file: %s" % e)
        return 0, 1

    fmt = detect_format(data, path)
    if fmt is None:
        print("  [SKIP] unrecognised format")
        return 0, 1

    try:
        found = PARSERS[fmt](data, path.name, decode=not dry_run)
    except Exception as e:
        print("  [SKIP] parse error: %s: %s" % (type(e).__name__, e))
        return 0, 1

    if not found:
        print("  no samples found")
        return 0, 0

    found.sort(key=lambda s: (s.inst, s.smp))

    subfolder_name = cap_subfolder(path.name)
    subfolder = output_dir / subfolder_name

    # Budget the filename against the full absolute path, so a deep -o
    # shrinks names automatically instead of overflowing MAX_PATH.
    try:
        prefix_len = len(str(subfolder.resolve()))
    except OSError:
        prefix_len = len(str(subfolder))
    budget = MAX_PATH - prefix_len - 1
    if budget < 12:
        print("  [SKIP] output path too deep for Windows path limits")
        return 0, 1

    if dry_run:
        for s in found:
            if s.skipped:
                print("  [DRY] %02d-%02d  SKIPPED: %s" % (s.inst, s.smp, s.skipped))
                continue
            name = s.filename(path.name, use_names, budget)
            if name is None:
                print("  [DRY] %02d-%02d  SKIPPED: no filename fits the path limit"
                      % (s.inst, s.smp))
                continue
            print("  [DRY] %s" % name)
            print("        %s" % s.audio_line())
        return len([s for s in found if not s.skipped]), 0

    subfolder.mkdir(parents=True, exist_ok=True)

    used_names = set()
    count = 0

    for s in found:
        if s.skipped:
            print("  [SKIP] %02d-%02d %s" % (s.inst, s.smp, s.skipped))
            continue
        if not s.pcm:
            continue

        name = s.filename(path.name, use_names, budget)
        if name is None:
            print("  [SKIP] %02d-%02d no filename fits the path limit"
                  % (s.inst, s.smp))
            continue

        # Truncation can make two names collide.
        if name.lower() in used_names:
            stem, ext = name[:-4], name[-4:]
            n = 2
            while True:
                cand = "%s_%d%s" % (stem, n, ext)
                if len(cand) > budget and len(stem) > FIELD_FLOOR:
                    stem = stem[:-1]
                    continue
                if cand.lower() not in used_names:
                    name = cand
                    break
                n += 1
        used_names.add(name.lower())
        s.final_name = name

        try:
            write_wav(subfolder / name, s.pcm, s.channels, s.framerate)
        except Exception as e:
            print("  [WARN] failed writing %s: %s" % (name, e))
            continue
        print("  ok  %s" % name)
        count += 1

    log_name = "_%s.txt" % sanitize(path.name)
    try:
        write_log(subfolder / log_name, path.name, fmt, found, use_names, count)
        print("  log %s" % log_name)
    except Exception as e:
        print("  [WARN] failed writing log: %s" % e)

    return count, 0


def collect_inputs(patterns, take_all, recurse=True, exclude_dir=None):
    """Expand files, folders and wildcard patterns into a file list.

    Windows shells do not expand wildcards, so the script does it itself.
    On Linux the shell has already expanded them and the names fall through
    the plain-file branch unchanged.

    exclude_dir is the output directory. It is skipped during scanning so a
    second run does not try to parse the WAVs written by the first.
    """
    result = []
    seen = set()
    walk = 'rglob' if recurse else 'glob'

    excluded = None
    if exclude_dir is not None:
        try:
            excluded = Path(exclude_dir).resolve()
        except OSError:
            excluded = None

    def is_excluded(p):
        """True for our own output: anything under the output folder,
        a log file, or a WAV (never a module, even under --all)."""
        if p.suffix.lower() == '.wav':
            return True
        if p.name.startswith('_') and p.suffix.lower() == '.txt':
            return True
        if excluded is not None:
            try:
                rp = p.resolve()
            except OSError:
                return False
            if rp == excluded or excluded in rp.parents:
                return True
        return False

    def add(p, trusted=False):
        if p in seen or not p.is_file():
            return
        if is_excluded(p):
            return
        if not trusted and not take_all and p.suffix.lower() not in SUPPORTED_EXTENSIONS:
            return
        seen.add(p)
        result.append(p)

    def scan_dir(d):
        for f in sorted(getattr(d, walk)('*')):
            add(f)

    for raw in patterns:
        p = Path(raw)

        # An explicitly named file is always taken, whatever its extension
        if p.is_file():
            add(p, trusted=True)
            continue

        if p.is_dir():
            scan_dir(p)
            continue

        if any(c in raw for c in '*?['):
            matches = sorted(Path(m) for m in glob.glob(raw, recursive=True))
            if not matches:
                print("[WARN] no matches for pattern: %s" % raw)
            # A pattern naming a concrete extension (*.it) is trusted;
            # a bare * still gets filtered unless --all is given.
            pattern_ext = Path(raw).suffix.lower()
            trusted = bool(pattern_ext) and '*' not in pattern_ext and '?' not in pattern_ext
            for m in matches:
                if m.is_dir():
                    scan_dir(m)
                else:
                    add(m, trusted=trusted)
            continue

        print("[WARN] not found: %s" % raw)

    return result


TOOL = 'trackerextract'
VERSION = '1.0'


# ===========================================================================
# Coloured help
# ===========================================================================

def _colour_enabled():
    """Colour unless NO_COLOR is set or stdout is not a terminal."""
    if os.environ.get('NO_COLOR'):
        return False
    if not hasattr(sys.stdout, 'isatty') or not sys.stdout.isatty():
        return False
    if sys.platform == 'win32':
        # Enable VT100 processing so ANSI renders in cmd and PowerShell.
        try:
            import ctypes
            k = ctypes.windll.kernel32
            h = k.GetStdHandle(-11)
            mode = ctypes.c_uint32()
            if not k.GetConsoleMode(h, ctypes.byref(mode)):
                return False
            k.SetConsoleMode(h, mode.value | 0x0004)
        except Exception:
            return False
    return True


def print_help():
    c = _colour_enabled()

    def s(code, text):
        return ("\033[%sm%s\033[0m" % (code, text)) if c else text

    title = lambda t: s('1;97', t)        # bold white
    head = lambda t: s('1;36', t)         # bold cyan
    flag = lambda t: s('92', t)           # bright green
    req = lambda t: s('93', t)            # yellow
    dim = lambda t: s('90', t)            # dim grey
    lit = lambda t: s('97', t)            # bright white

    out = []
    A = out.append

    A("")
    A("  %s  %s" % (title(TOOL), dim('v' + VERSION)))
    A("  %s" % dim('Extract embedded samples from tracker modules as 16-bit WAV.'))
    A("")

    A("  %s" % head('USAGE'))
    A("    %s %s" % (lit(TOOL), dim('[inputs ...] [options]')))
    A("")
    A("    %s  %s" % (flag('inputs'.ljust(22)),
                      dim('files, folders or wildcard patterns')))
    A("    %s  %s" % (' ' * 22, dim('omit them and pass --all to use the current folder')))
    A("")

    A("  %s" % head('OPTIONS'))
    rows = [
        ('-o, --output DIR', 'output directory (default: ./%s_out)' % TOOL),
        ('--names', 'build long filenames from the embedded names'),
        ('--all', 'try every file found, not just known module'),
        ('', 'extensions; with no inputs, means the current folder'),
        ('--no-recurse', 'do not descend into subfolders'),
        ('--dry-run', 'list what would be extracted, write nothing'),
        ('-h, --help', 'this help'),
    ]
    for name, desc in rows:
        A("    %s  %s" % (flag(name.ljust(22)) if name else ' ' * 22, dim(desc)))
    A("")

    A("  %s" % head('FORMATS'))
    A("    %s  %s" % (lit('.it '.ljust(22)),
                      dim('Impulse Tracker, incl. IT214/IT215 compression')))
    A("    %s  %s" % (lit('.xm '.ljust(22)), dim('FastTracker 2')))
    A("    %s  %s" % (lit('.s3m'.ljust(22)), dim('Scream Tracker 3')))
    A("    %s  %s" % (lit('.mod'.ljust(22)),
                      dim('ProTracker, plus .nst .wow .m15 .mod15')))
    A("")

    A("  %s" % head('NAMING'))
    A("    %s" % dim('default'))
    A("      %s" % lit('01-01_[song.it].wav'))
    A("    %s" % dim('with --names'))
    A("      %s" % lit('01-01_Drumkit--Closed_Hihat_[song.it]-HIHATC1.wav'))
    A("      %s" % dim('inst-smp_instrument--sample_[module]-dosname'))
    A("")
    A("    %s" % dim('Name fields are taken from the module. A missing field'))
    A("    %s" % dim('becomes "unnamed"; if none are usable the short form is'))
    A("    %s" % dim('used instead. Tracker placeholders such as UNKNOWN and'))
    A("    %s" % dim('DOS-style extensions (.WAV, .PAT) are dropped.'))
    A("")

    A("  %s" % head('OUTPUT'))
    A("    %s  %s" % (lit('<out>/<module>/'.ljust(22)), dim('one folder per module')))
    A("    %s  %s" % (lit('_<module>.txt'.ljust(22)),
                      dim('log: every slot, full untruncated names')))
    A("")

    A("  %s" % head('NOTES'))
    notes = [
        'All output is signed 16-bit PCM WAV, mono or stereo as stored.',
        'Sample rates come from the module; MOD uses its finetune table.',
        'Filenames are budgeted against the Windows 260-character path',
        'limit, so a deep -o shortens names rather than failing.',
        'The output folder is never scanned as input, so repeat runs are',
        'safe. Wildcards are expanded by the tool, so cmd.exe works.',
        'S3M ADPCM samples are reported and skipped, not mangled.',
    ]
    for n in notes:
        A("    %s" % dim(n))
    A("")

    A("  %s" % head('EXAMPLES'))
    ex = [
        ('%s --all' % TOOL, 'everything in the current folder'),
        ('%s --all --names' % TOOL, 'the same, with long filenames'),
        ('%s song.it' % TOOL, 'one module'),
        ('%s *.it --names' % TOOL, 'every IT module here'),
        ('%s C:\\mods -o D:\\samples' % TOOL, 'a whole library'),
        ('%s . --no-recurse' % TOOL, 'this folder only'),
        ('%s *.s3m --dry-run' % TOOL, 'see what would happen'),
    ]
    for cmd, desc in ex:
        A("    %s" % lit(cmd))
        A("      %s" % dim(desc))
    A("")

    sys.stdout.write('\n'.join(out) + '\n')


def main():
    argv = sys.argv[1:]

    # Scan argv directly so help always works, whatever else is present.
    if any(a in ('-h', '--help', '-help', '/?') for a in argv):
        print_help()
        sys.exit(0)

    # A bare run shows help; --all is what says "the current folder".
    if not argv:
        print_help()
        sys.exit(1)

    ap = argparse.ArgumentParser(prog=TOOL, add_help=False)
    ap.add_argument('inputs', nargs='*')
    ap.add_argument('-o', '--output', default='./%s_out' % TOOL)
    ap.add_argument('--names', action='store_true')
    ap.add_argument('--all', action='store_true', dest='take_all')
    ap.add_argument('--no-recurse', action='store_true')
    ap.add_argument('--dry-run', action='store_true')

    try:
        args = ap.parse_args(argv)
    except SystemExit:
        print_help()
        sys.exit(2)

    if not args.inputs:
        if not args.take_all:
            print_help()
            sys.exit(1)
        args.inputs = ['.']

    output_dir = Path(args.output)

    files = collect_inputs(args.inputs, args.take_all,
                           not args.no_recurse, output_dir)
    if not files:
        print("No module files found.")
        sys.exit(1)

    if not args.dry_run:
        output_dir.mkdir(parents=True, exist_ok=True)

    print("Found %d file(s) to process." % len(files))
    if args.dry_run:
        print("--- DRY RUN - no files will be written ---")

    total = 0
    skipped = 0
    for f in files:
        got, skip = extract_file(f, output_dir, args.dry_run, args.names)
        total += got
        skipped += skip

    print("\nDone. %d sample(s) %s, %d file(s) skipped."
          % (total, 'listed' if args.dry_run else 'extracted', skipped))
    if not args.dry_run and total:
        print("Output: %s" % output_dir.resolve())


if __name__ == '__main__':
    main()
