#!/usr/bin/env python3
"""Exercise the shipped Bash prompt hooks without starting a user shell."""

import os
from pathlib import Path
import subprocess
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
    def run_hook(self, command, prompt_command="unset PROMPT_COMMAND", setup=""):
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


if __name__ == "__main__":
    unittest.main()
