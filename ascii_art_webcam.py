#!/usr/bin/env python3
"""
Live webcam to high-detail ASCII art for macOS terminals.

Install:
    python3 -m pip install opencv-python numpy

Useful commands:
    python3 ascii_art_webcam.py --list-cameras
    python3 ascii_art_webcam.py --camera 0 --width 180 --color
    python3 ascii_art_webcam.py --camera 1 --width 160 --rotate 90 --no-mirror

Runtime keys:
    q      quit
    c      toggle ANSI color
    e      cycle edge/detail enhancement
    i      invert brightness mapping
    m      mirror/unmirror
    h      show/hide the status line
"""

from __future__ import annotations

import argparse
import math
import os
import platform
import select
import shutil
import subprocess
import sys
import termios
import time
import tty
from dataclasses import dataclass
from functools import lru_cache
from typing import Any, Iterable


cv2: Any = None
np: Any = None


ASCII_RAMPS = {
    # Ordered from darkest to brightest for dark terminal backgrounds.
    "dense": " .'`^\",:;Il!i~+_-?][}{1)(|\\/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$",
    "clean": " .:-=+*#%@",
    "bold": "  ..::--==++**##%%@@",
    "thin": " .,:;irsXA253hMHGS#9B&@",
}

EDGE_STEPS = (0.0, 0.25, 0.45, 0.70, 1.0)


@dataclass
class RenderSettings:
    chars: str
    color: bool
    invert: bool
    edge_strength: float
    clahe: bool
    gamma: float
    sharpen: float
    dither: bool
    mirror: bool
    rotate: int
    cell_aspect: float
    hud: bool
    color_quantum: int


@dataclass
class CameraInfo:
    index: int
    width: int
    height: int
    fps: float


class TerminalSession:
    """Small terminal wrapper for clean, low-flicker drawing."""

    def __init__(self, alt_screen: bool) -> None:
        self.alt_screen = alt_screen
        self.is_tty = sys.stdin.isatty() and sys.stdout.isatty()
        self._fd: int | None = None
        self._old_termios: list[Any] | None = None

    def __enter__(self) -> "TerminalSession":
        try:
            if self.is_tty:
                self._fd = sys.stdin.fileno()
                self._old_termios = termios.tcgetattr(self._fd)
                tty.setcbreak(self._fd)

            if self.alt_screen:
                sys.stdout.write("\x1b[?1049h")
            sys.stdout.write("\x1b[?25l\x1b[2J\x1b[H")
            sys.stdout.flush()
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        try:
            sys.stdout.write("\x1b[0m\x1b[?25h")
            if self.alt_screen:
                sys.stdout.write("\x1b[?1049l")
            sys.stdout.flush()
        finally:
            if self._fd is not None and self._old_termios is not None:
                termios.tcsetattr(self._fd, termios.TCSADRAIN, self._old_termios)

    def read_key(self) -> str | None:
        if not self.is_tty or self._fd is None:
            return None

        ready, _, _ = select.select([sys.stdin], [], [], 0)
        if not ready:
            return None

        try:
            return os.read(self._fd, 1).decode("utf-8", errors="ignore")
        except OSError:
            return None


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Render a Mac webcam or iPhone Continuity Camera feed as live, "
            "high-detail ASCII art in your terminal."
        )
    )
    parser.add_argument(
        "--list-cameras",
        action="store_true",
        help="probe available OpenCV camera indexes and print macOS camera names",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run the renderer on a synthetic frame without opening a camera",
    )
    parser.add_argument("--camera", type=int, default=0, help="OpenCV camera index to use")
    parser.add_argument(
        "--backend",
        choices=("auto", "avfoundation", "any"),
        default="auto",
        help="camera backend; auto uses AVFoundation on macOS",
    )
    parser.add_argument(
        "--probe-count",
        type=int,
        default=8,
        help="number of camera indexes to probe with --list-cameras",
    )
    parser.add_argument(
        "--capture-width",
        type=int,
        default=1280,
        help="requested camera capture width before ASCII conversion",
    )
    parser.add_argument(
        "--capture-height",
        type=int,
        default=720,
        help="requested camera capture height before ASCII conversion",
    )
    parser.add_argument(
        "--capture-fps",
        type=float,
        default=30.0,
        help="requested camera capture frame rate",
    )
    parser.add_argument(
        "--width",
        type=int,
        default=None,
        help="maximum ASCII columns; defaults to current terminal width",
    )
    parser.add_argument(
        "--height",
        type=int,
        default=None,
        help="maximum ASCII rows; defaults to current terminal height",
    )
    parser.add_argument(
        "--fps",
        type=float,
        default=30.0,
        help="render frame cap; use 0 for uncapped",
    )
    parser.add_argument(
        "--frames",
        type=int,
        default=0,
        help="render this many camera frames and exit; 0 means run until quit",
    )
    parser.add_argument(
        "--charset",
        choices=tuple(ASCII_RAMPS),
        default="dense",
        help="character ramp to use",
    )
    parser.add_argument(
        "--chars",
        default=None,
        help="custom darkest-to-brightest character ramp",
    )
    parser.add_argument(
        "--color",
        action="store_true",
        help="render with ANSI truecolor foreground color",
    )
    parser.add_argument(
        "--color-quantum",
        type=int,
        default=24,
        help="color rounding step for faster ANSI output; lower is more accurate",
    )
    parser.add_argument(
        "--invert",
        action="store_true",
        help="invert the brightness mapping for light terminal backgrounds",
    )
    parser.add_argument(
        "--edge-strength",
        type=float,
        default=0.45,
        help="edge/detail boost from 0.0 to 1.5",
    )
    parser.add_argument(
        "--no-clahe",
        action="store_true",
        help="disable local contrast enhancement",
    )
    parser.add_argument(
        "--gamma",
        type=float,
        default=1.0,
        help="gamma correction; values below 1 brighten shadows, above 1 darken",
    )
    parser.add_argument(
        "--sharpen",
        type=float,
        default=0.35,
        help="unsharp mask amount from 0.0 to 1.5",
    )
    parser.add_argument(
        "--dither",
        action="store_true",
        help="apply ordered dithering for smoother tone transitions",
    )
    mirror_group = parser.add_mutually_exclusive_group()
    mirror_group.add_argument(
        "--mirror",
        dest="mirror",
        action="store_true",
        help="mirror the image horizontally",
    )
    mirror_group.add_argument(
        "--no-mirror",
        dest="mirror",
        action="store_false",
        help="do not mirror the image horizontally",
    )
    parser.set_defaults(mirror=True)
    parser.add_argument(
        "--rotate",
        type=int,
        choices=(0, 90, 180, 270),
        default=0,
        help="rotate camera frames clockwise before rendering",
    )
    parser.add_argument(
        "--cell-aspect",
        type=float,
        default=0.50,
        help="terminal character width divided by height; 0.45-0.55 is typical",
    )
    parser.add_argument(
        "--hud",
        action="store_true",
        help="show a one-line status/control bar below the ASCII frame",
    )
    parser.add_argument(
        "--no-alt-screen",
        action="store_true",
        help="draw in the current terminal buffer instead of an alternate screen",
    )
    args = parser.parse_args(list(argv))
    for name in ("capture_width", "capture_height", "capture_fps", "width", "height", "gamma", "cell_aspect", "probe_count"):
        value = getattr(args, name)
        if value is not None and (not math.isfinite(value) or value <= 0):
            parser.error(f"--{name.replace('_', '-')} must be finite and greater than 0")
    for name in ("camera", "fps", "frames", "edge_strength", "sharpen"):
        value = getattr(args, name)
        if not math.isfinite(value) or value < 0:
            parser.error(f"--{name.replace('_', '-')} must be finite and nonnegative")
    if args.chars is not None:
        if len(set(args.chars)) < 2 or any(not 32 <= ord(char) <= 126 for char in args.chars):
            parser.error("--chars must contain at least two different printable ASCII characters")
    return args


def load_dependencies() -> None:
    global cv2, np

    try:
        import cv2 as cv2_module
        import numpy as np_module
    except ImportError as exc:
        missing = exc.name or "opencv-python/numpy"
        raise SystemExit(
            f"Missing Python dependency: {missing}\n\n"
            "Install the runtime packages with:\n"
            "    python3 -m pip install opencv-python numpy"
        ) from exc

    cv2 = cv2_module
    np = np_module


def backend_value(name: str) -> int:
    if name == "any":
        return cv2.CAP_ANY
    if name == "avfoundation":
        return getattr(cv2, "CAP_AVFOUNDATION", cv2.CAP_ANY)
    if platform.system() == "Darwin" and hasattr(cv2, "CAP_AVFOUNDATION"):
        return cv2.CAP_AVFOUNDATION
    return cv2.CAP_ANY


def system_camera_names() -> list[str]:
    if platform.system() != "Darwin":
        return []

    try:
        result = subprocess.run(
            ["system_profiler", "SPCameraDataType", "-detailLevel", "mini"],
            capture_output=True,
            check=False,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []

    names: list[str] = []
    for raw_line in result.stdout.splitlines():
        line = raw_line.strip()
        if not line.endswith(":"):
            continue
        name = line[:-1].strip()
        if not name or name.lower() == "camera":
            continue
        if name not in names:
            names.append(name)
    return names


def probe_cameras(count: int, backend: int) -> list[CameraInfo]:
    found: list[CameraInfo] = []
    for index in range(max(0, count)):
        cap = cv2.VideoCapture(index, backend)
        try:
            if not cap.isOpened() and backend != cv2.CAP_ANY:
                cap.release()
                cap = cv2.VideoCapture(index, cv2.CAP_ANY)

            if not cap.isOpened():
                continue

            ok, frame = cap.read()
            if ok and frame is not None:
                height, width = frame.shape[:2]
                fps = float(cap.get(cv2.CAP_PROP_FPS) or 0.0)
                found.append(CameraInfo(index=index, width=width, height=height, fps=fps))
        finally:
            cap.release()
    return found


def print_camera_list(args: argparse.Namespace) -> None:
    backend = backend_value(args.backend)
    cameras = probe_cameras(args.probe_count, backend)
    names = system_camera_names()

    print("OpenCV camera indexes:")
    if cameras:
        for camera in cameras:
            fps = f"{camera.fps:.1f} fps" if camera.fps > 0 else "fps unknown"
            print(f"  {camera.index}: {camera.width}x{camera.height}, {fps}")
    else:
        print("  No camera indexes opened.")

    if names:
        print("\nmacOS camera devices reported by system_profiler:")
        for name in names:
            print(f"  - {name}")

    print(
        "\nTip: iPhone Continuity Camera usually appears as another OpenCV "
        "index. Try --camera 1, --camera 2, etc. if --camera 0 is the built-in webcam."
    )


def open_camera(args: argparse.Namespace) -> Any:
    backend = backend_value(args.backend)
    cap = cv2.VideoCapture(args.camera, backend)
    try:
        if not cap.isOpened() and backend != cv2.CAP_ANY:
            cap.release()
            cap = cv2.VideoCapture(args.camera, cv2.CAP_ANY)

        if not cap.isOpened():
            raise SystemExit(camera_error(args.camera))

        cap.set(cv2.CAP_PROP_FRAME_WIDTH, float(args.capture_width))
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, float(args.capture_height))
        cap.set(cv2.CAP_PROP_FPS, float(args.capture_fps))
        cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)

        ok, frame = cap.read()
        if not ok or frame is None:
            raise SystemExit(camera_error(args.camera))
    except BaseException:
        cap.release()
        raise
    return cap


def camera_error(index: int) -> str:
    return (
        f"Could not open camera index {index}.\n\n"
        "Try:\n"
        "    python3 ascii_art_webcam.py --list-cameras\n"
        "    python3 ascii_art_webcam.py --camera 1\n\n"
        "On macOS, also make sure Terminal, iTerm, or VS Code has Camera "
        "permission in System Settings > Privacy & Security > Camera. If FaceTime, "
        "Zoom, or Teams is already using the same camera, close it or choose another source."
    )


def settings_from_args(args: argparse.Namespace) -> RenderSettings:
    chars = args.chars if args.chars else ASCII_RAMPS[args.charset]
    if len(set(chars)) < 2:
        raise SystemExit("--chars must contain at least two different characters")

    if args.gamma <= 0:
        raise SystemExit("--gamma must be greater than 0")
    if args.cell_aspect <= 0:
        raise SystemExit("--cell-aspect must be greater than 0")

    return RenderSettings(
        chars=chars,
        color=args.color,
        invert=args.invert,
        edge_strength=max(0.0, min(float(args.edge_strength), 1.5)),
        clahe=not args.no_clahe,
        gamma=float(args.gamma),
        sharpen=max(0.0, min(float(args.sharpen), 1.5)),
        dither=args.dither,
        mirror=bool(args.mirror),
        rotate=int(args.rotate),
        cell_aspect=float(args.cell_aspect),
        hud=bool(args.hud),
        color_quantum=max(1, min(int(args.color_quantum), 255)),
    )


def synthetic_frame(width: int = 1280, height: int = 720) -> Any:
    x = np.linspace(0, 1, width, dtype=np.float32)
    y = np.linspace(0, 1, height, dtype=np.float32)
    xx, yy = np.meshgrid(x, y)

    blue = np.clip((1.0 - xx) * 255, 0, 255)
    green = np.clip((0.35 + yy * 0.65) * 255, 0, 255)
    red = np.clip((xx * 0.75 + (1.0 - yy) * 0.25) * 255, 0, 255)
    frame = np.dstack([blue, green, red]).astype(np.uint8)

    for radius, color in ((240, (30, 30, 30)), (170, (230, 230, 230)), (95, (20, 20, 20))):
        cv2.circle(frame, (width // 2, height // 2), radius, color, thickness=8)

    for offset in range(-width, width, 90):
        cv2.line(frame, (offset, 0), (offset + height, height), (255, 255, 255), 2)

    cv2.rectangle(frame, (70, 70), (width - 70, height - 70), (10, 10, 10), 6)
    cv2.putText(
        frame,
        "ASCII WEBCAM SELF TEST",
        (90, height - 100),
        cv2.FONT_HERSHEY_SIMPLEX,
        1.6,
        (245, 245, 245),
        4,
        cv2.LINE_AA,
    )
    return frame


def run_self_test(args: argparse.Namespace) -> int:
    settings = settings_from_args(args)
    frame = transform_frame(synthetic_frame(), settings)
    cols = int(args.width or 96)
    rows = int(args.height or 32)
    char_grid, small_bgr = frame_to_ascii(frame, cols, rows, settings)
    output = render_ascii(char_grid, small_bgr, settings)
    lines = output.splitlines()

    if char_grid.shape != (rows, cols):
        raise RuntimeError(f"unexpected grid shape {char_grid.shape}, expected {(rows, cols)}")
    if len(lines) != rows:
        raise RuntimeError(f"unexpected line count {len(lines)}, expected {rows}")
    if not any(char.strip() for char in char_grid.ravel().tolist()):
        raise RuntimeError("renderer produced only blank characters")

    print("Renderer self-test passed.")
    print(f"  frame: 1280x720 synthetic BGR")
    print(f"  ascii: {cols}x{rows}")
    print(f"  mode: {'ANSI color' if settings.color else 'grayscale'}")
    print(f"  ramp: {len(settings.chars)} characters")
    print()
    print(output)
    return 0


def transform_frame(frame: Any, settings: RenderSettings) -> Any:
    if settings.rotate == 90:
        frame = cv2.rotate(frame, cv2.ROTATE_90_CLOCKWISE)
    elif settings.rotate == 180:
        frame = cv2.rotate(frame, cv2.ROTATE_180)
    elif settings.rotate == 270:
        frame = cv2.rotate(frame, cv2.ROTATE_90_COUNTERCLOCKWISE)

    if settings.mirror:
        frame = cv2.flip(frame, 1)
    return frame


def terminal_limits(args: argparse.Namespace, settings: RenderSettings) -> tuple[int, int]:
    size = shutil.get_terminal_size(fallback=(140, 48))
    # Keep the final column unused to avoid terminal autowrap at the right edge.
    max_cols = min(args.width or size.columns, max(1, size.columns - 1))
    max_rows = min(args.height or size.lines, size.lines)
    if settings.hud:
        max_rows -= 1
    return max(1, int(max_cols)), max(1, int(max_rows))


def fit_ascii_size(
    frame_width: int,
    frame_height: int,
    max_cols: int,
    max_rows: int,
    cell_aspect: float,
) -> tuple[int, int]:
    frame_aspect = frame_width / max(1, frame_height)
    cols = max_cols
    rows = int(round(cols * cell_aspect / frame_aspect))

    if rows > max_rows:
        rows = max_rows
        cols = int(round(rows * frame_aspect / cell_aspect))

    cols = max(1, min(max_cols, cols))
    rows = max(1, min(max_rows, rows))
    return cols, rows


@lru_cache(maxsize=16)
def gamma_lut(gamma: float) -> Any:
    if abs(gamma - 1.0) < 0.001:
        return None
    return np.array([((i / 255.0) ** gamma) * 255 for i in range(256)]).astype("uint8")


@lru_cache(maxsize=8)
def ordered_dither(rows: int, cols: int, levels: int) -> Any:
    bayer8 = np.array(
        [
            [0, 48, 12, 60, 3, 51, 15, 63],
            [32, 16, 44, 28, 35, 19, 47, 31],
            [8, 56, 4, 52, 11, 59, 7, 55],
            [40, 24, 36, 20, 43, 27, 39, 23],
            [2, 50, 14, 62, 1, 49, 13, 61],
            [34, 18, 46, 30, 33, 17, 45, 29],
            [10, 58, 6, 54, 9, 57, 5, 53],
            [42, 26, 38, 22, 41, 25, 37, 21],
        ],
        dtype=np.float32,
    )
    tiled = np.tile(bayer8, (rows // 8 + 1, cols // 8 + 1))[:rows, :cols]
    step = 255.0 / max(1, levels)
    return (tiled / 64.0 - 0.5) * step


def frame_to_ascii(frame: Any, cols: int, rows: int, settings: RenderSettings) -> tuple[Any, Any]:
    small_bgr = cv2.resize(frame, (cols, rows), interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(small_bgr, cv2.COLOR_BGR2GRAY)

    if settings.clahe:
        gray = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8)).apply(gray)

    lut = gamma_lut(settings.gamma)
    if lut is not None:
        gray = cv2.LUT(gray, lut)

    if settings.sharpen > 0:
        blurred = cv2.GaussianBlur(gray, (0, 0), sigmaX=1.0)
        gray = cv2.addWeighted(gray, 1.0 + settings.sharpen, blurred, -settings.sharpen, 0)

    if settings.edge_strength > 0:
        softened = cv2.GaussianBlur(gray, (3, 3), 0)
        grad_x = cv2.Sobel(softened, cv2.CV_32F, 1, 0, ksize=3)
        grad_y = cv2.Sobel(softened, cv2.CV_32F, 0, 1, ksize=3)
        magnitude = cv2.magnitude(grad_x, grad_y)
        peak = float(magnitude.max())
        if peak > 0:
            magnitude = (magnitude / peak) * 255.0
            gray = np.clip(
                gray.astype(np.float32) + magnitude * settings.edge_strength,
                0,
                255,
            ).astype(np.uint8)

    if settings.dither:
        levels = len(settings.chars) - 1
        gray = np.clip(
            gray.astype(np.float32) + ordered_dither(rows, cols, levels),
            0,
            255,
        ).astype(np.uint8)

    levels = len(settings.chars) - 1
    indexes = np.rint((gray.astype(np.float32) / 255.0) * levels).astype(np.intp)
    indexes = np.clip(indexes, 0, levels)
    if settings.invert:
        indexes = levels - indexes

    lookup = np.array(list(settings.chars))
    return lookup[indexes], small_bgr


def quantize_color(value: int, quantum: int) -> int:
    if quantum <= 1:
        return value
    return min(255, (value // quantum) * quantum)


def render_ascii(char_grid: Any, color_bgr: Any, settings: RenderSettings) -> str:
    if not settings.color:
        return "\n".join("".join(row.tolist()) for row in char_grid)

    lines: list[str] = []
    quantum = settings.color_quantum
    for y, row in enumerate(char_grid):
        pieces: list[str] = []
        last_color: tuple[int, int, int] | None = None
        for x, char in enumerate(row):
            b, g, r = color_bgr[y, x]
            color = (
                quantize_color(int(r), quantum),
                quantize_color(int(g), quantum),
                quantize_color(int(b), quantum),
            )
            if color != last_color:
                pieces.append(f"\x1b[38;2;{color[0]};{color[1]};{color[2]}m")
                last_color = color
            pieces.append(str(char))
        pieces.append("\x1b[0m")
        lines.append("".join(pieces))
    return "\n".join(lines)


def cycle_edge_strength(current: float) -> float:
    closest_index = min(range(len(EDGE_STEPS)), key=lambda i: abs(EDGE_STEPS[i] - current))
    return EDGE_STEPS[(closest_index + 1) % len(EDGE_STEPS)]


def handle_key(key: str | None, settings: RenderSettings) -> bool:
    if not key:
        return True

    char = key[0].lower()
    if char in {"q", "\x03", "\x1b"}:
        return False
    if char == "c":
        settings.color = not settings.color
    elif char == "e":
        settings.edge_strength = cycle_edge_strength(settings.edge_strength)
    elif char == "i":
        settings.invert = not settings.invert
    elif char == "m":
        settings.mirror = not settings.mirror
    elif char == "h":
        settings.hud = not settings.hud
    return True


def hud_line(
    width: int,
    fps: float,
    cols: int,
    rows: int,
    settings: RenderSettings,
) -> str:
    mode = "color" if settings.color else "gray"
    mirror = "mirror" if settings.mirror else "normal"
    invert = "invert" if settings.invert else "dark-bg"
    text = (
        f"q quit | c {mode} | e edge {settings.edge_strength:.2f} | "
        f"i {invert} | m {mirror} | h hud | {fps:4.1f} fps | {cols}x{rows}"
    )
    if len(text) > width:
        return text[: max(0, width - 1)]
    return text.ljust(width)


def run(args: argparse.Namespace) -> None:
    settings = settings_from_args(args)
    cap = open_camera(args)
    frame_period = 0.0 if args.fps <= 0 else 1.0 / args.fps
    fps_window_started = time.monotonic()
    fps_frames = 0
    rendered_frames = 0
    measured_fps = 0.0

    try:
        with TerminalSession(alt_screen=not args.no_alt_screen) as terminal:
            while True:
                loop_started = time.monotonic()
                ok, frame = cap.read()
                if not ok or frame is None:
                    raise RuntimeError("Camera stopped returning frames")

                frame = transform_frame(frame, settings)
                frame_height, frame_width = frame.shape[:2]
                max_cols, max_rows = terminal_limits(args, settings)
                cols, rows = fit_ascii_size(
                    frame_width,
                    frame_height,
                    max_cols,
                    max_rows,
                    settings.cell_aspect,
                )
                char_grid, small_bgr = frame_to_ascii(frame, cols, rows, settings)
                output = render_ascii(char_grid, small_bgr, settings)

                now = time.monotonic()
                fps_frames += 1
                elapsed = now - fps_window_started
                if elapsed >= 0.5:
                    measured_fps = fps_frames / elapsed
                    fps_window_started = now
                    fps_frames = 0

                sys.stdout.write("\x1b[H")
                sys.stdout.write(output.replace("\n", "\x1b[K\n") + "\x1b[K")
                terminal_rows = shutil.get_terminal_size(fallback=(140, 48)).lines
                if settings.hud and rows < min(args.height or terminal_rows, terminal_rows):
                    sys.stdout.write("\n")
                    sys.stdout.write(hud_line(max_cols, measured_fps, cols, rows, settings))
                sys.stdout.write("\x1b[0m\x1b[J")
                sys.stdout.flush()

                rendered_frames += 1
                if args.frames > 0 and rendered_frames >= args.frames:
                    break

                if not handle_key(terminal.read_key(), settings):
                    break

                render_elapsed = time.monotonic() - loop_started
                if frame_period > render_elapsed:
                    time.sleep(frame_period - render_elapsed)
    finally:
        cap.release()


def main(argv: Iterable[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    load_dependencies()

    if args.list_cameras:
        print_camera_list(args)
        return 0

    if args.self_test:
        return run_self_test(args)

    run(args)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
