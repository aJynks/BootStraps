#!/usr/bin/env python3
"""
yt-downloader_script.py - shared yt-dlp backend for the yt-*.bat wrappers.

Called as:
    python yt-downloader_script.py <mode> [args...]

Each .bat wrapper is a one-liner that passes its mode name plus %*:
    yt-video.bat  ->  python "%~dp0yt-downloader_script.py" video %*

Implemented modes:
    video   - single YouTube video at best (or capped) quality

Adding a mode later:
    1. write  help_<mode>()  and  run_<mode>(args)
    2. register it in MODES at the bottom
    3. add a one-line .bat wrapper
Shared plumbing (dependency check, yt-dlp -U, help/update/--help commands,
running yt-dlp) lives in the COMMON section and is reused by every mode.

Standard library only. Requires yt-dlp.exe (and ffmpeg.exe for merging) on PATH.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


# ============================================================
# COMMON
# ============================================================

INSTALL_YTDLP = ("curl -L -o yt-dlp.exe "
                 "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe")
INSTALL_FFMPEG = "choco install ffmpeg"

EXIT_USAGE = 2
EXIT_MISSING_DEP = 9009


class UsageError(Exception):
    """Bad command-line input; message is shown above the mode's usage line."""


def find_ytdlp():
    """Return path to yt-dlp, or exit with an install command."""
    path = shutil.which("yt-dlp")
    if not path:
        print("Error: yt-dlp.exe not found on PATH.")
        print(f"Install: {INSTALL_YTDLP}")
        sys.exit(EXIT_MISSING_DEP)
    return path


def check_ffmpeg():
    """Warn (non-fatal) if ffmpeg is missing - needed to merge video+audio."""
    if not shutil.which("ffmpeg"):
        print("Warning: ffmpeg.exe not found on PATH - yt-dlp cannot merge separate")
        print("         video/audio streams and will fall back to lower quality.")
        print(f"         Install: {INSTALL_FFMPEG}")
        print()


def update_ytdlp(ytdlp, fatal=False):
    """Run yt-dlp -U. Non-fatal by default: warn and carry on."""
    print("Updating yt-dlp...")
    rc = subprocess.call([ytdlp, "-U"])
    if rc != 0 and not fatal:
        print("Warning: yt-dlp update failed - continuing with current version.")
    print()
    return rc


def split_extra(args):
    """Split args at --extra. Returns (own_args, extra_args)."""
    for i, a in enumerate(args):
        if a.lower() == "--extra":
            return args[:i], args[i + 1:]
    return args, []


def run_ytdlp(cmd):
    """Run yt-dlp, returning its exit code (130 on Ctrl+C)."""
    try:
        return subprocess.call(cmd)
    except KeyboardInterrupt:
        print("\nAborted.")
        return 130


# ============================================================
# MODE: video
# ============================================================

# Filename: channelName-YYYY-MM-DD---videotitle-[1080p].ext
VIDEO_OUTTMPL = ("%(channel,uploader|Unknown)s-"
                 "%(upload_date>%Y-%m-%d|0000-00-00)s---"
                 "%(title)s-[%(height|NA)sp].%(ext)s")

VIDEO_QUALITY = {f"-{h}p": h for h in (144, 240, 360, 480, 720, 1080, 1440, 2160, 4320)}
VIDEO_QUALITY.update({"-2k": 1440, "-4k": 2160, "-8k": 4320})

VIDEO_CONTAINERS = ("-mp4", "-mkv")


def help_video(bat):
    print(f"""
{bat} - YouTube single video downloader

Commands:
  {bat} help       Show this help.
  {bat} update     Update yt-dlp (yt-dlp.exe -U).
  {bat} --help     Show yt-dlp help.

Download:
  {bat} "<URL>" [quality] [-mp4 | -mkv] [--extra <yt-dlp args...>]
      Always quote the URL (URLs containing & break otherwise).
      Flags may go before or after the URL; --extra must be last.
      Only the single video is downloaded, even from a playlist URL.

Quality (optional cap, default = highest available):
  -144p -240p -360p -480p -720p -1080p
  -1440p / -2k    -2160p / -4k    -4320p / -8k

Container:
  (default)  mp4 if the streams fit, otherwise mkv
  -mp4       always mp4 (prefers H.264/AAC)
  -mkv       always mkv (best codec, usually AV1/VP9)
  No re-encoding is ever done - merging/remuxing is a stream copy.

Output (current folder):
  channelName-YYYY-MM-DD---videotitle-[1080p].mp4
  channelName-YYYY-MM-DD---videotitle-[1080p].txt   (video description)

Examples:
  {bat} "https://www.youtube.com/watch?v=abc123"
  {bat} "https://www.youtube.com/watch?v=abc123" -1080p
  {bat} -4k -mkv "https://www.youtube.com/watch?v=abc123"
  {bat} "https://youtu.be/abc123" --extra --cookies-from-browser firefox

Requirements:
  yt-dlp.exe on PATH (runs yt-dlp -U before each download)
  ffmpeg.exe on PATH (for merging video+audio)
""")


def usage_video(bat):
    print("Usage:")
    print(f"  {bat} help | update | --help")
    print(f'  {bat} "<URL>" [quality] [-mp4 | -mkv] [--extra <yt-dlp args...>]')
    print(f'  Run "{bat} help" for the full list of flags.')


def parse_video(args):
    own, extra = split_extra(args)
    url = cap = cont = None
    for a in own:
        low = a.lower()
        if low in VIDEO_QUALITY:
            if cap is not None:
                raise UsageError("Only one quality flag allowed.")
            cap = VIDEO_QUALITY[low]
        elif low in VIDEO_CONTAINERS:
            if cont is not None:
                raise UsageError("Only one of -mp4 / -mkv allowed.")
            cont = low[1:]
        elif a.startswith("-"):
            raise UsageError(f'Unknown flag "{a}"\n'
                             "Use --extra to pass options straight to yt-dlp.")
        else:
            if url is not None:
                raise UsageError(f'More than one URL given: "{a}"')
            url = a
    if url is None:
        raise UsageError("No URL given.")
    return url, cap, cont, extra


def write_description(info_path):
    """Read the after_move info JSON and write <videofile>.txt with the description."""
    try:
        lines = Path(info_path).read_text(encoding="utf-8").strip().splitlines()
    except OSError:
        lines = []
    if not lines:
        print("Warning: no video info captured - description .txt not written.")
        return
    info = json.loads(lines[-1])
    video = info.get("filepath")
    if not video:
        print("Warning: final file path unknown - description .txt not written.")
        return
    txt = Path(video).with_suffix(".txt")
    txt.write_text(info.get("description") or "", encoding="utf-8")
    print()
    print(f"Video      : {Path(video).name}")
    print(f"Description: {txt.name}")


def run_video(args, bat):
    url, cap, cont, extra = parse_video(args)

    ytdlp = find_ytdlp()
    check_ffmpeg()
    update_ytdlp(ytdlp)

    res = f"res:{cap}" if cap else "res"
    if cont == "mkv":
        sort, merge, remux = res, "mkv", ["--remux-video", "mkv"]
        cdesc = "mkv (forced, best codec)"
    elif cont == "mp4":
        sort, merge, remux = f"{res},ext:mp4:m4a", "mp4", ["--remux-video", "mp4"]
        cdesc = "mp4 (forced)"
    else:
        sort, merge, remux = f"{res},ext:mp4:m4a", "mp4/mkv", []
        cdesc = "mp4, mkv only if needed"

    print(f"URL      : {url}")
    print(f"Quality  : {f'best up to {cap}p' if cap else 'highest available'}")
    print(f"Container: {cdesc}")
    if extra:
        print(f"Extra    : {subprocess.list2cmdline(extra)}")
    print()

    # yt-dlp dumps the final info JSON here after the file is moved into place;
    # we read it back to write the description .txt (overwriting, never appending).
    fd, info_path = tempfile.mkstemp(prefix="yt-video-info-", suffix=".json")
    os.close(fd)
    try:
        cmd = [
            ytdlp,
            "--no-playlist",
            "-f", "bv*+ba/b",
            "-S", sort,
            "--merge-output-format", merge,
            *remux,
            "-o", VIDEO_OUTTMPL,
            "--print-to-file", "after_move:%()j", info_path,
            *extra,
            "--", url,
        ]
        rc = run_ytdlp(cmd)
        write_description(info_path)
    finally:
        try:
            os.remove(info_path)
        except OSError:
            pass
    return rc


# ============================================================
# DISPATCH
# ============================================================

# mode name -> (bat name shown in help, help func, usage func, run func)
MODES = {
    "video": ("yt-video", help_video, usage_video, run_video),
}


def main(argv):
    try:
        sys.stdout.reconfigure(errors="replace")
    except AttributeError:
        pass

    if not argv or argv[0] not in MODES:
        print("Error: first argument must be a mode: " + ", ".join(MODES))
        print("This script is normally called via its .bat wrappers.")
        return EXIT_USAGE

    bat, help_fn, usage_fn, run_fn = MODES[argv[0]]
    args = argv[1:]

    # Hard commands: do one thing and exit
    first = args[0].lower() if args else ""
    if first == "help":
        help_fn(bat)
        return 0
    if first == "update":
        return update_ytdlp(find_ytdlp(), fatal=True)
    if first == "--help":
        return subprocess.call([find_ytdlp(), "--help"])
    if not args:
        usage_fn(bat)
        return EXIT_USAGE

    try:
        return run_fn(args, bat)
    except UsageError as e:
        print(f"Error: {e}")
        print()
        usage_fn(bat)
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
