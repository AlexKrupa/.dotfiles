import tempfile
import unittest
from pathlib import Path

import conditions


class TextTest(unittest.TestCase):
    def test_none_is_empty(self):
        self.assertEqual(conditions.text("none"), "")

    def test_full_inlines_imports(self):
        text = conditions.text("full")

        self.assertIn("# Personal AI instructions", text)
        self.assertIn("## Dotfiles", text)
        self.assertIn("# Claude Code notes for the skills", text)
        self.assertNotIn("@~/.config/agents/instructions-agents.md", text)

    def test_variant_reads_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "variant.md"
            path.write_text("X")

            self.assertEqual(conditions.text(f"variant:{path}"), "X")

    def test_config_name_uses_variant_file_stem(self):
        self.assertEqual(conditions.config_name("variant:/tmp/no-candidates.md"), "variant-no-candidates")
        self.assertEqual(conditions.config_name("full"), "full")

    def test_unknown_condition_fails(self):
        with self.assertRaises(ValueError):
            conditions.text("half")


if __name__ == "__main__":
    unittest.main()
