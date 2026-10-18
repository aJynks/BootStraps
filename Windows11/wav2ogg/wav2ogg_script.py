import argparse
import subprocess
import sys
from pathlib import Path


# Common audio formats FFmpeg can read.
AUDIO_EXTENSIONS = {
    ".wav",
    ".mp3",
    ".flac",
    ".aac",
    ".m4a",
    ".wma",
    ".aiff",
    ".aif",
    ".opus",
    ".mp2",
    ".ac3",
    ".ape",
    ".wv",
    ".caf",
    ".au",
    ".snd",
}

# Common tracker/module formats supported through libopenmpt/libmodplug.
TRACKER_EXTENSIONS = {
    ".mod",
    ".xm",
    ".s3m",
    ".it",
    ".mptm",
    ".mtm",
    ".med",
    ".okt",
    ".stm",
    ".ult",
    ".669",
    ".far",
    ".amf",
    ".dmf",
    ".dsm",
    ".imf",
    ".j2b",
    ".mdl",
    ".mo3",
    ".psm",
    ".ptm",
    ".umx",
    ".wow",
}

SUPPORTED_EXTENSIONS = AUDIO_EXTENSIONS | TRACKER_EXTENSIONS


def convert_to_ogg(input_file, output_file=None, quality=5, mono=False):
    input_path = Path(input_file)

    if not input_path.exists():
        print(f"ERROR: File not found: {input_path}")
        return False

    if output_file is None:
        output_path = input_path.with_suffix(".ogg")
    else:
        output_path = Path(output_file)

    try:
        if input_path.resolve() == output_path.resolve():
            print(f"SKIPPED: Input is already the output file: {input_path}")
            return False
    except OSError:
        pass

    command = [
        "ffmpeg",
        "-y",
        "-i", str(input_path),
        "-vn",
    ]

    if mono:
        command += [
            "-ac", "1",
        ]

    command += [
        "-c:a", "libvorbis",
        "-q:a", str(quality),
        str(output_path),
    ]

    print(f"Converting: {input_path}")
    print(f"       To: {output_path}")

    try:
        subprocess.run(command, check=True)
    except FileNotFoundError:
        print("ERROR: ffmpeg was not found in PATH.")
        sys.exit(1)
    except subprocess.CalledProcessError:
        print(f"ERROR: FFmpeg failed converting: {input_path}")
        return False

    print(f"Created: {output_path}")
    return True


def convert_all(quality=5, mono=False):
    files = []

    for path in Path.cwd().iterdir():
        if not path.is_file():
            continue

        if path.suffix.lower() in SUPPORTED_EXTENSIONS:
            files.append(path)

    files.sort(key=lambda p: p.name.lower())

    if not files:
        print("No supported audio or tracker files found.")
        return

    print(f"Found {len(files)} supported file(s).")
    print()

    successful = 0
    failed = 0

    for input_path in files:
        if convert_to_ogg(
            input_path,
            quality=quality,
            mono=mono,
        ):
            successful += 1
        else:
            failed += 1

        print()

    print("------------------------------")
    print(f"Converted: {successful}")
    print(f"Failed:    {failed}")


def main():
    parser = argparse.ArgumentParser(
        description="Convert audio and tracker files to Ogg Vorbis for Doom."
    )

    parser.add_argument(
        "input",
        nargs="?",
        help="Input audio or tracker file"
    )

    parser.add_argument(
        "output",
        nargs="?",
        help="Output OGG file"
    )

    parser.add_argument(
        "-mono",
        "--mono",
        action="store_true",
        help="Convert audio to mono"
    )

    parser.add_argument(
        "-quality",
        "--quality",
        type=int,
        default=5,
        metavar="N",
        help="Vorbis quality level (default: 5)"
    )

    parser.add_argument(
        "-all",
        "--all",
        action="store_true",
        dest="convert_all_files",
        help="Convert all supported audio and tracker files in the current directory"
    )

    args = parser.parse_args()

    if args.convert_all_files:
        convert_all(
            quality=args.quality,
            mono=args.mono,
        )
        return

    if not args.input:
        parser.error("input file required unless -all/--all is used")

    convert_to_ogg(
        args.input,
        args.output,
        quality=args.quality,
        mono=args.mono,
    )


if __name__ == "__main__":
    main()