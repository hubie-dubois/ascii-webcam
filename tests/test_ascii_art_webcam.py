"""Camera-free renderer and lifecycle regression tests."""

import contextlib
import io
import os
import re
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ascii_art_webcam as app


class RendererTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        app.load_dependencies()

    def settings(self, *args):
        return app.settings_from_args(app.parse_args(args))

    def test_gamma_matches_documented_direction(self):
        self.assertGreater(app.gamma_lut(0.5)[128], 128)
        self.assertLess(app.gamma_lut(2.0)[128], 128)
        self.assertIsNone(app.gamma_lut(1.0))
        self.assertEqual(app.gamma_lut(0.5)[0], 0)
        self.assertEqual(app.gamma_lut(2.0)[255], 255)

    def test_rejects_invalid_arguments_before_camera_access(self):
        cases = [
            ("--gamma", "nan"), ("--gamma", "0"), ("--cell-aspect", "inf"),
            ("--fps", "nan"), ("--fps", "-1"), ("--frames", "-1"),
            ("--width", "0"), ("--height", "-5"), ("--capture-fps", "0"),
            ("--capture-width", "-1"), ("--capture-height", "0"),
            ("--edge-strength", "inf"), ("--sharpen", "nan"),
            ("--probe-count", "0"), ("--camera", "-1"),
            ("--chars", ""), ("--chars", "aa"), ("--chars", ".\n#"),
            ("--chars", ".\x1b#"), ("--chars", ".界"),
        ]
        for argv in cases:
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as caught:
                    app.parse_args(argv)
                self.assertEqual(caught.exception.code, 2)
        self.assertEqual(app.parse_args(["--fps", "0", "--frames", "0"]).fps, 0)

    def test_terminal_limits_respect_actual_terminal_and_user_caps(self):
        for width, height in [(1, 1), (5, 3), (80, 24)]:
            for hud in (False, True):
                args = app.parse_args(["--width", "200", "--height", "100"])
                settings = self.settings(*(["--hud"] if hud else []))
                with patch.object(app.shutil, "get_terminal_size", return_value=os.terminal_size((width, height))):
                    cols, rows = app.terminal_limits(args, settings)
                self.assertLessEqual(cols, max(1, width - 1))
                self.assertLessEqual(rows, max(1, height - int(hud)))
                self.assertGreaterEqual(cols, 1)
                self.assertGreaterEqual(rows, 1)
        with patch.object(app.shutil, "get_terminal_size", return_value=os.terminal_size((80, 24))):
            self.assertEqual(app.terminal_limits(app.parse_args(["--width", "4", "--height", "2"]), self.settings()), (4, 2))

    def test_fit_respects_even_tiny_bounds(self):
        for width, height in [(1, 10000), (10000, 1), (1920, 1080)]:
            for max_cols, max_rows in [(1, 1), (3, 2), (80, 24)]:
                cols, rows = app.fit_ascii_size(width, height, max_cols, max_rows, 0.5)
                self.assertTrue(1 <= cols <= max_cols)
                self.assertTrue(1 <= rows <= max_rows)

    def test_mapping_inversion_and_color_output(self):
        frame = app.np.array([[[0, 0, 0], [255, 255, 255]]], dtype=app.np.uint8)
        settings = self.settings("--chars", " .#", "--no-clahe", "--sharpen", "0", "--edge-strength", "0")
        chars, colors = app.frame_to_ascii(frame, 2, 1, settings)
        self.assertEqual(app.render_ascii(chars, colors, settings), " #")
        settings.invert = True
        chars, colors = app.frame_to_ascii(frame, 2, 1, settings)
        self.assertEqual(app.render_ascii(chars, colors, settings), "# ")
        settings.color = True
        output = app.render_ascii(chars, colors, settings)
        self.assertEqual(re.sub(r"\x1b\[[0-9;]*m", "", output), "# ")
        self.assertTrue(output.endswith("\x1b[0m"))

    def test_synthetic_pipeline_all_rotations_and_modes(self):
        frame = app.synthetic_frame(320, 180)
        for rotation in (0, 90, 180, 270):
            for color in (False, True):
                settings = self.settings("--rotate", str(rotation), "--dither", "--gamma", "0.8")
                settings.color = color
                transformed = app.transform_frame(frame, settings)
                expected = (180, 320) if rotation in (0, 180) else (320, 180)
                self.assertEqual(transformed.shape[:2], expected)
                chars, colors = app.frame_to_ascii(transformed, 24, 10, settings)
                output = re.sub(r"\x1b\[[0-9;]*m", "", app.render_ascii(chars, colors, settings))
                self.assertEqual(len(output.splitlines()), 10)
                self.assertTrue(all(len(line) == 24 for line in output.splitlines()))

    def test_long_custom_ramp_does_not_overflow_indexes(self):
        settings = self.settings("--chars", "." * 40000 + "#", "--no-clahe", "--sharpen", "0", "--edge-strength", "0")
        frame = app.np.full((1, 1, 3), 255, dtype=app.np.uint8)
        chars, _ = app.frame_to_ascii(frame, 1, 1, settings)
        self.assertEqual(chars[0, 0], "#")


class LifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        app.load_dependencies()

    def test_terminal_restored_when_output_fails(self):
        session = app.TerminalSession(True)
        session._fd, session._old_termios = 9, ["original"]
        output = MagicMock()
        output.write.side_effect = BrokenPipeError
        with patch.object(app.sys, "stdout", output), patch.object(app.termios, "tcsetattr") as restore:
            with self.assertRaises(BrokenPipeError):
                session.__exit__(None, None, None)
            restore.assert_called_once_with(9, app.termios.TCSADRAIN, ["original"])

    def test_failed_terminal_entry_restores_cbreak(self):
        session = app.TerminalSession(True)
        session.is_tty = True
        output, stdin = MagicMock(), MagicMock()
        stdin.fileno.return_value = 9
        output.flush.side_effect = BrokenPipeError
        with patch.object(app.sys, "stdout", output), patch.object(app.sys, "stdin", stdin), \
             patch.object(app.termios, "tcgetattr", return_value=["original"]), \
             patch.object(app.termios, "tcsetattr") as restore, patch.object(app.tty, "setcbreak"):
            with self.assertRaises(BrokenPipeError):
                session.__enter__()
            restore.assert_called_once()

    def test_camera_released_if_terminal_entry_fails(self):
        cap = MagicMock()
        terminal = MagicMock()
        terminal.__enter__.side_effect = OSError("terminal unavailable")
        with patch.object(app, "open_camera", return_value=cap), patch.object(app, "TerminalSession", return_value=terminal):
            with self.assertRaises(OSError):
                app.run(app.parse_args([]))
        cap.release.assert_called_once()

    def test_camera_released_on_configuration_failure(self):
        cap = MagicMock()
        cap.isOpened.return_value = True
        cap.set.side_effect = RuntimeError("capture configuration failed")
        with patch.object(app.cv2, "VideoCapture", return_value=cap):
            with self.assertRaises(RuntimeError):
                app.open_camera(app.parse_args([]))
        cap.release.assert_called_once()

    def test_probe_releases_camera_on_read_failure(self):
        cap = MagicMock()
        cap.isOpened.return_value = True
        cap.read.side_effect = RuntimeError("capture failed")
        with patch.object(app.cv2, "VideoCapture", return_value=cap):
            with self.assertRaises(RuntimeError):
                app.probe_cameras(1, app.cv2.CAP_ANY)
        cap.release.assert_called_once()

    def test_batched_keys_are_not_discarded(self):
        session = app.TerminalSession(False)
        session.is_tty, session._fd = True, 9
        with patch.object(app.select, "select", return_value=([9], [], [])), \
             patch.object(app.os, "read", return_value=b"c") as read:
            self.assertEqual(session.read_key(), "c")
            read.assert_called_once_with(9, 1)

    def test_live_loop_clears_rows_and_releases_camera(self):
        args = app.parse_args(["--frames", "1", "--width", "4", "--height", "2", "--no-clahe"])
        cap = MagicMock()
        cap.read.return_value = (True, app.np.full((10, 10, 3), 128, dtype=app.np.uint8))
        with patch.object(app, "open_camera", return_value=cap), patch.object(app, "TerminalSession"), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            app.run(args)
        self.assertIn("\x1b[K\n", output.getvalue())
        cap.release.assert_called_once()


if __name__ == "__main__":
    unittest.main()
