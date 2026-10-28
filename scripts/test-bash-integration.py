#!/usr/bin/env python3
"""Exercise shipped Bash prompt and Bash/Zsh directory-reporting hooks."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = (
    Path(__file__).resolve().parents[1]
    / "src/shell-integration/bash/ghostty.bash"
).read_text()
# Extract the actual functions and modern hook registration, so the tests
# also run on macOS's Bash 3.2 without sourcing startup files or bash-preexec.
PRECMD = SOURCE[
    SOURCE.index("function __ghostty_precmd() {") : SOURCE.index(
        "function __ghostty_preexec() {"
    )
]
HOOKS = SOURCE[
    SOURCE.index("  __ghostty_restore_status() {") : SOURCE.index(
        '\nelse\n  builtin source "$(dirname -- "${BASH_SOURCE[0]}")/bash-preexec.sh"'
    )
]


class BashPromptTests(unittest.TestCase):
    def run_hook(
        self, command, prompt_command="unset PROMPT_COMMAND", setup="", cwd=None
    ):
        script = "\n".join(
            (
                'PS1="test> "; PS2="> "; PS0=; GHOSTTY_SHELL_FEATURES=',
                '_ghostty_executing=1; _ghostty_last_reported_cwd="$PWD"',
                prompt_command,
                PRECMD,
                HOOKS,
                setup,
                command,
            )
        )
        return subprocess.run(
            [os.environ.get("BASH_TEST_BIN", "/bin/bash"), "--noprofile", "--norc", "-c", script],
            check=True,
            capture_output=True,
            cwd=cwd,
        ).stdout

    def assert_status(self, output, status):
        self.assertIn(f"\x1b]133;D;{status};aid=".encode(), output)

    def test_hook_preserves_command_status(self):
        for status in (0, 1, 7, 127):
            with self.subTest(status=status):
                self.assert_status(
                    self.run_hook(f"(exit {status}); __ghostty_hook"), status
                )

    def test_precmd_accepts_explicit_status(self):
        self.assert_status(self.run_hook("true; __ghostty_precmd 7"), 7)

    def test_precmd_accepts_implicit_status_for_bash_preexec(self):
        self.assert_status(self.run_hook("(exit 7); __ghostty_precmd"), 7)

    def test_scalar_prompt_command_sees_original_status(self):
        output = self.run_hook(
            '(exit 7); eval "$PROMPT_COMMAND"; printf "SEEN=%s" "$seen"; '
            'test "${__ghostty_status+x}" != x',
            "PROMPT_COMMAND='seen=$?; true'",
        )
        self.assert_status(output, 7)
        self.assertIn(b"SEEN=7", output)

    def test_array_prompt_command_keeps_its_type_and_entries(self):
        output = self.run_hook(
            'declare -p PROMPT_COMMAND; test "${#PROMPT_COMMAND[@]}" = 2',
            "declare -a PROMPT_COMMAND=('true')",
        )
        self.assertIn(b"declare -a", output)
        self.assertIn(b"__ghostty_hook", output)

    def test_registering_twice_does_not_duplicate_hooks(self):
        output = self.run_hook(
            '(exit 7); eval "$PROMPT_COMMAND"',
            "PROMPT_COMMAND='true'",
            setup=HOOKS,
        )
        self.assert_status(output, 7)
        self.assertEqual(output.count(b"\x1b]133;D;"), 1)

    def test_directory_reports_cannot_inject_terminal_sequences(self):
        for name in (r"literal\a\e]52;c;SGVsbG8=\a", "raw\x07\x1b]52;c;SGVsbG8=\x07"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / name
                path.mkdir()
                output = self.run_hook(
                    "true; __ghostty_precmd",
                    setup="_ghostty_last_reported_cwd=",
                    cwd=str(path),
                )
                self.assertNotIn(b"\x1b]52;", output)
                reported = output.split(b"\x1b]7;kitty-shell-cwd://", 1)[1]
                expected_path = str(path.resolve()).replace("\x07", "").replace("\x1b", "")
                self.assertTrue(reported.endswith(expected_path.encode() + b"\x07"))
                self.assertEqual(reported.count(b"\x07"), 1)


class ZshDirectoryTests(unittest.TestCase):
    def report(self, path, host="safe-host"):
        source = (
            Path(__file__).resolve().parents[1]
            / "src/shell-integration/zsh/ghostty-integration"
        ).read_text()
        start = source.index("    _ghostty_report_pwd() {")
        function = source[start : source.index("\n    chpwd_functions=", start)]
        return subprocess.run(
            [
                os.environ.get("ZSH_TEST_BIN", "/bin/zsh"), "-df", "-c",
                '_ghostty_fd=1; HOST=$TEST_HOST\n' + function + "\n_ghostty_report_pwd",
            ],
            check=True,
            capture_output=True,
            cwd=str(path),
            env={**os.environ, "TEST_HOST": host},
        ).stdout

    def test_directory_reports_cannot_inject_terminal_sequences(self):
        for name in (r"literal\a\e]52;c;SGVsbG8=\a", "raw\x07\x1b]52;c;SGVsbG8=\x07"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / name
                path.mkdir()
                expected_path = str(path.resolve()).replace("\x07", "").replace("\x1b", "")
                self.assertEqual(
                    self.report(path),
                    b"\x1b]7;kitty-shell-cwd://safe-host" + expected_path.encode() + b"\x07",
                )

    def test_hostname_controls_are_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            self.assertEqual(
                self.report(path, "unsafe\x07\x1bhost"),
                b"\x1b]7;kitty-shell-cwd://unsafehost" + str(path.resolve()).encode() + b"\x07",
            )


if __name__ == "__main__":
    unittest.main()
