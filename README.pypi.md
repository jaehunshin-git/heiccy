# heic-converter-tui

Convert HEIC images to JPEG or PNG with a command-line interface or an arrow-key
TUI. Images are processed locally, and source files remain unchanged.

The Python package name is **heic-converter-tui** and its installed command is
**heic-converter**. The source repository is
[heiccy](https://github.com/jaehunshin-git/heiccy).

## Features

- Convert directories of `.heic` files to JPEG or PNG.
- Choose English or Korean in the interactive TUI.
- Adjust JPEG quality, PNG compression, metadata handling, and file conflicts.
- Include subdirectories while preserving their relative output paths.
- Apply image orientation; preserve PNG transparency and composite JPEG alpha
  on white.
- Preserve supported Apple HDR gain maps in 16-bit PNG on macOS 15 or later.

## Supported environment

- Python 3.11 or later.
- macOS is the primary supported platform.
- Pillow and pillow-heif provide image decoding and encoding and are installed
  as dependencies. On macOS, PyObjC provides access to native ImageIO APIs.
- HDR PNG depends on macOS 15 or later, supported ImageIO APIs, and a supported
  source gain map. Other environments use the SDR base image; JPEG output is SDR.
- The TUI requires an interactive terminal. Scripts must specify `--format`.

## Installation

Install with `uv`:

```bash
uv tool install heic-converter-tui
```

Or with `pipx`:

```bash
pipx install heic-converter-tui
```

Check the installed command:

```bash
heic-converter --help
```

## Usage

### Interactive TUI

Run without arguments in a real terminal:

```bash
heic-converter
```

Choose English or Korean, then select the input and output directories, format,
quality or compression, recursion, metadata policy, and conflict policy. Use the
up/down arrow keys and Enter to select options, and type paths directly. Review
the summary before starting. Press Ctrl+C or select Cancel to exit with code 130.

### CLI

```bash
# Convert HEIC files directly inside input to JPEG.
heic-converter --input ./input --output ./output --format jpeg

# Convert a directory tree to PNG, preserving relative paths.
heic-converter --input ./photos --output ./converted --format png --recursive

# Customize JPEG quality and remove metadata.
heic-converter --input ./photos --output ./converted --format jpeg \
  --jpeg-quality 95 --metadata strip --on-conflict rename
```

Input and output must be different directories. Single-file CLI input is not
supported. Only case-insensitive `.heic` extensions are processed; `.heif`, video,
image sequences, and auxiliary-image extraction are outside the supported scope.
If the output directory is inside the input directory, its tree is excluded
from discovery.

| Option | Values or purpose | Default |
| --- | --- | --- |
| `-i, --input PATH` | Input directory | `./input` |
| `-o, --output PATH` | Output directory | `./output` |
| `-f, --format FORMAT` | `jpeg`, `png` | Required outside the TUI |
| `--jpeg-quality N` | `1`–`100` | `90` |
| `--png-compression N` | `0`–`9` | `6` |
| `--recursive` | Include subdirectories | Off |
| `--metadata POLICY` | `safe`, `preserve`, `strip` | `safe` |
| `--on-conflict POLICY` | `rename`, `skip`, `overwrite`, `error` | `rename` |

The `safe` metadata policy removes GPS and XMP while retaining other EXIF data
and ICC profiles where possible. `preserve` retains supported metadata; `strip`
removes EXIF and XMP. HDR PNG keeps the color information needed for rendering.
PNG compression settings apply to the Pillow SDR path; the native HDR encoder
controls its own compression.

Output uses `.jpeg` or `.png`. The default `rename` policy chooses an available
numbered name; `skip` keeps existing files, `overwrite` replaces them, and `error`
records a failure and continues. Files are completed in a temporary file before
publication to avoid exposing incomplete output.

| Exit code | Meaning |
| --- | --- |
| `0` | All inputs were processed successfully. |
| `1` | One or more files could not be read, converted, or saved. |
| `2` | Invalid arguments, paths, or options, or no HEIC files found. |
| `130` | Interactive cancellation or interruption. |

## Upgrade or uninstall

Use the tool that installed the package:

```bash
uv tool upgrade heic-converter-tui
uv tool uninstall heic-converter-tui
```

```bash
pipx upgrade heic-converter-tui
pipx uninstall heic-converter-tui
```

## Source and support

Source code: [jaehunshin-git/heiccy](https://github.com/jaehunshin-git/heiccy).
Report bugs through [GitHub Issues](https://github.com/jaehunshin-git/heiccy/issues).

## License

The project is distributed under the
[MIT License](https://github.com/jaehunshin-git/heiccy/blob/main/LICENSE).
Third-party dependencies, including codecs distributed with pillow-heif, retain
their own licenses and notices.
