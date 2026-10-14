<img src="docs/assets/branding/heiccy-app-icon.png" alt="heiccy app icon" width="96" height="96" />

# heiccy

[한국어](README.md) · [English](README.en.md)

![macOS](https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-arm64-555555)
![Local processing](https://img.shields.io/badge/Processing-Local%20only-2E8B57)
[![License](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

> HEIC to JPEG or PNG, automatically.

**heiccy** is a macOS menu bar app that converts supported HEIC clipboard images
into JPEG or PNG, ready to paste with **Command-V**. Photos are processed on your
computer and source files remain unchanged. The app includes its Python runtime
and codecs, so you do not need to install Python separately.

The same repository provides a CLI and an arrow-key TUI for directory conversion
and scripts. See [CLI/TUI](#clitui) for Python package installation and
[README.md](README.md) for Korean documentation.

**Release status:** Version 1.0.0 is being prepared. The official download entry
point is [heiccy Releases](https://github.com/jaehunshin-git/heiccy/releases).
A DMG is available only after its release has been published.

## macOS app installation

### Requirements

- Apple Silicon Mac (arm64), macOS 15 or later
- No separate Python installation required to run the packaged app

### DMG download and installation

The app's distribution destination is [GitHub Releases](https://github.com/jaehunshin-git/heiccy/releases).
Download the DMG and checksum from the same published release. Until that
release is available, these steps apply to a build made from source:

1. Obtain the DMG and its matching `.sha256` file from the same build or release.
2. In the directory containing both files, verify the checksum:

   ```bash
   shasum -a 256 -c heiccy-1.0.0-arm64.dmg.sha256
   ```

3. Open the DMG and drag **heiccy.app** to **Applications**.
4. Open **heiccy** from Applications; its icon appears in the menu bar.

Current builds use ad-hoc signing and are not notarized. If macOS blocks the first
launch, follow [Apple's instructions](https://support.apple.com/102445).

### Replacing an earlier app build

The new filename does not replace an existing `HEIC Converter.app` automatically.
Quit the earlier app from its menu bar menu before installing `heiccy.app`, so it
can restore any clipboard data it published. Keep the earlier bundle outside
Applications as a backup, then install and open `heiccy.app` explicitly. Do not
run both copies together. If you return to the earlier build, quit heiccy first.

The bundle identifier and settings key are unchanged, so saved conversion options
and legacy output paths remain available. Pause is session-only; automatic
conversion starts enabled on the next launch.

### Build the app from source

See the [app build and release guide](docs/build.md) (in Korean) to build from source.

## Using heiccy

1. Copy a supported local HEIC file in Finder, or supported raw HEIC image data.
2. Wait for the conversion-complete notice. Pasting before completion may paste
   the original image.
3. Paste with **Command-V** in the receiving app.

| Control | Action |
| --- | --- |
| Left-click the menu bar icon | Show or hide the current clipboard's file names, thumbnails, and conversion status. |
| Right-click the menu bar icon | Pause/resume automatic conversion, open Settings, or quit. |
| Settings | Choose JPEG/PNG, quality, compression, and metadata handling. |
| Reopen the running app from Finder or Spotlight | Show the clipboard panel. |

Automatic conversion starts enabled on each launch. Pause lasts for the current
session; conversion options persist. The panel closes when focus moves away.
Copy detection does not open it, and the app keeps no clipboard history.

The default output is JPEG at quality 90. PNG compression defaults to 6 and the
metadata policy is `safe`, which removes GPS and XMP where supported. On macOS 15+
with supported Apple HDR gain maps, PNG output can preserve HDR in 16-bit form;
JPEG output is SDR. HDR conversion depends on the source and ImageIO support.

### Supported input and clipboard safety

- Readable local regular `.heic` file URLs and raw `public.heic` data are supported.
- Non-HEIC items retain their order and preservable clipboard representations.
  Results are published only after every HEIC conversion succeeds and the
  clipboard still contains the same copy. A newer copy cancels stale publication.
- Files referenced by converted clipboard items are temporary. Source files are
  unchanged. Normal quit restores the original clipboard when it still contains
  the app's results; recovery after an abnormal exit is not guaranteed.
- File promises, offline files, and Photos asset references combined with file
  URLs inside a `.photoslibrary` are unsupported. Export an unmodified original
  and copy it from Finder for the file workflow. Videos are excluded.
- Receiving apps choose which clipboard representations to accept; pasting every
  item in every app is not guaranteed.

See [clipboard compatibility](docs/compatibility.md) for supported inputs and
receiving-app limitations. Report user-facing bugs in
[heiccy Issues](https://github.com/jaehunshin-git/heiccy/issues).

## CLI/TUI

[![PyPI](https://img.shields.io/pypi/v/heic-converter-tui?logo=pypi&logoColor=white)](https://pypi.org/project/heic-converter-tui/)
[![Python package downloads](https://api.pepy.tech/personalized-badge/heic-converter-tui?period=month&units=none&left_color=grey&right_color=blue&left_text=downloads%2Fmonth)](https://pepy.tech/projects/heic-converter-tui)
[![Python](https://img.shields.io/badge/Python-%E2%89%A53.11-3776AB?logo=python&logoColor=white)](https://www.python.org/)

The [PyPI package](https://pypi.org/project/heic-converter-tui/) is the directory
converter for terminal users. Its distribution name remains `heic-converter-tui`
and its command remains `heic-converter`; installing it does not install the
standalone macOS app.

### CLI/TUI requirements

- Python 3.11 or later
- macOS is the primary supported platform
- `uv` or `pipx`

The installation command installs the required Pillow and pillow-heif runtime
dependencies.

### Install

With `uv`:

```bash
uv tool install heic-converter-tui
```

Or with `pipx`:

```bash
pipx install heic-converter-tui
```

The distribution name is `heic-converter-tui`; the installed command is
`heic-converter`.

```bash
heic-converter --help
```

### Run the TUI

Run the command without arguments in a real terminal:

```bash
heic-converter
```

Choose `한국어` or `English` first. The rest of the UI, including validation
messages, choices, the summary, and cancellation notices, follows that choice.
Use the `↑` and `↓` arrow keys to move between choices, press Enter to confirm,
and type paths directly.

```text
HEIC Converter TUI

? Language / 언어 English

HEIC conversion settings

? Input directory path ./input
? Output directory path ./output
? Output format JPEG
? JPEG quality High (90)
? Include subdirectories? No — current directory only
? Metadata handling Keep safely (recommended) — remove sensitive data such as GPS
? When an output file has the same name Rename (recommended) — create a numbered filename

Configuration summary
  Input directory: input
  Output directory: output
  Output format: JPEG (JPEG quality 90)
  Include subdirectories: No
  Metadata: Keep safely
  File conflict handling: Rename

? Start conversion with these settings? Start
```

Press `Ctrl+C` or choose `Cancel` at the last prompt to exit without converting;
the command returns exit code `130`.

### Run from the command line

Specify an output format when running from a script or non-interactive environment.

```bash
# Convert HEIC files directly inside input to JPEG.
heic-converter --input ./input --output ./output --format jpeg

# Convert HEIC files in photos to PNG.
heic-converter --input ./photos --output ./converted --format png

# Include subdirectories and create a new name if output files already exist.
heic-converter \
  --input ./photos \
  --output ./converted \
  --format jpeg \
  --recursive \
  --on-conflict rename
```

Omitting `--format` outside a TTY produces a usage error.

### Upgrade or uninstall

For an installation made with `uv`:

```bash
uv tool upgrade heic-converter-tui
uv tool uninstall heic-converter-tui
```

For an installation made with `pipx`:

```bash
pipx upgrade heic-converter-tui
pipx uninstall heic-converter-tui
```


## 📚 Behavior and options

### Command format

```text
heic-converter --input INPUT --output OUTPUT --format {jpeg,png} [OPTIONS]
```

`--input` and `--output` are directory paths. They default to `./input` and
`./output`, respectively. They cannot refer to the same directory, and single-file
input is not supported.

| Option | Description | Default |
| --- | --- | --- |
| `-i, --input PATH` | Input HEIC directory | `./input` |
| `-o, --output PATH` | Output directory | `./output` |
| `-f, --format {jpeg,png}` | Output format | Required outside the TUI |
| `--jpeg-quality N` | JPEG quality, from 1 to 100 | `90` |
| `--png-compression N` | PNG compression level, from 0 to 9 | `6` |
| `--recursive` | Search subdirectories | Off |
| `--metadata {safe,preserve,strip}` | Metadata policy | `safe` |
| `--on-conflict {rename,skip,overwrite,error}` | Output conflict policy | `rename` |

JPEG output uses the `.jpeg` extension, while PNG output uses `.png`.
The TUI offers practical quality and compression presets; the CLI accepts any valid
value within the ranges above.

### Metadata and image handling

| Policy | Behavior |
| --- | --- |
| `safe` | Removes GPS and XMP while retaining other EXIF data and ICC profiles where possible. |
| `preserve` | Retains EXIF, XMP, and ICC profiles where supported by the conversion libraries. |
| `strip` | Removes EXIF and XMP. HDR PNG retains its ICC profile or CICP color signaling required for correct rendering. |

The converter applies image orientation to pixels and, when metadata is written,
normalizes the output EXIF orientation value to `1`. JPEG does not support alpha,
so transparent pixels are composited on white; PNG keeps alpha channels.

On macOS 15 or later, HEIC images with an Apple HDR gain map are converted to
16-bit HDR PNG with an HDR color profile. The native HDR path selects the HEIC's
primary image even when its index is not zero; a generated multi-image HEIC verifies
the nonzero primary index, 16-bit PQ output, and metadata policies. This preserves
the source image's HDR brightness and color appearance on compatible displays. Other environments
save the base SDR image, which may look different from the HEIC on an HDR
display. JPEG output is SDR. App results report whether HDR was applied and the
reason for SDR fallback. HDR preservation depends on the source gain map and
available ImageIO APIs; it is not guaranteed for every HEIC. PNG compression
level applies to the Pillow SDR path; the native HDR encoder controls its own
compression.

### File discovery and conflict handling

- Only files with a case-insensitive `.heic` extension are processed; `.heif` is not supported.
- By default, only files directly in the input directory are considered. `--recursive` includes subdirectories and preserves their relative layout in the output directory.
- If the output directory is inside the input directory, its tree is excluded from discovery.
- `rename` deterministically chooses an available filename such as `photo.jpeg`, `photo-2.jpeg`, or `photo-3.jpeg`.
- `skip` leaves the existing output file untouched and skips that input.
- `overwrite` replaces an existing output file.
- `error` records the conflicting file as a failure and continues with the next input.
- Files are first completed in a temporary file inside the output directory, so incomplete output files are not exposed.

### Supported scope

The converter processes one primary still image from each HEIC file and produces
JPEG or PNG. It does not support:

- PDF or HWP/HWPX conversion
- OCR or text extraction
- Live Photo video processing
- Extracting auxiliary images, sequences, or video instead of the primary still image
- Single-file input through the CLI (the app uses clipboard input)

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Every input was processed successfully. |
| `1` | One or more files could not be read, converted, or saved. |
| `2` | An argument, path, or option is invalid, or no `.heic` files were found. |
| `130` | The interactive UI was interrupted with `Ctrl+C` or cancelled. |

## Releases and documentation

The macOS app is distributed through [GitHub Releases](https://github.com/jaehunshin-git/heiccy/releases),
and the CLI/TUI through [PyPI](https://pypi.org/project/heic-converter-tui/).
Their versions and release schedules are independent.

- [Clipboard compatibility and supported inputs](docs/compatibility.md) (Korean)
- [App build and release guide](docs/build.md) (Korean)
- [Release notes](docs/releases/v1.0.0.md) (Korean)
- [Third-party components and corresponding sources](docs/third-party-sources.md) (Korean)
- [Report a bug or suggest a feature](https://github.com/jaehunshin-git/heiccy/issues)

Automatic app updates, Intel support, Homebrew Cask, and Mac App Store distribution
are not available. Quit the app normally before replacing it with a newer DMG build.

## License

This project is distributed under the [MIT License](LICENSE).
Bundled third-party components retain their own licenses, including the codec
notices shipped with pillow-heif. See the app's
`Contents/Resources/Licenses` for the Python runtime and library notices.
