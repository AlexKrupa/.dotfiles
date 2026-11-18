"""The `CLAUDE.md` text of each condition.

- `none`: no text.
- `full`: `integrations/claude-code/CLAUDE.md`, as in daily use, with each `@<path>` import line
  replaced by the text of that file.
- `variant:<path>`: the text of the file at <path>.
"""
import re
from pathlib import Path

AGENTS = Path(__file__).resolve().parents[2]
CLAUDE_MD = AGENTS / "integrations" / "claude-code" / "CLAUDE.md"


def text(condition):
    if condition == "none":
        return ""
    if condition == "full":
        # Inlined, so that the run does not depend on how a project CLAUDE.md resolves imports
        # outside the repo.
        return re.sub(r"^@(\S+)$", lambda m: Path(m.group(1)).expanduser().read_text().rstrip("\n"),
                      CLAUDE_MD.read_text(), flags=re.MULTILINE)
    if condition.startswith("variant:"):
        return Path(condition.removeprefix("variant:")).expanduser().read_text()
    raise ValueError(f"unknown condition {condition!r}. Use none, full, or variant:<path>")


def config_name(condition):
    """Return the config dir name of the runs of a condition."""
    if condition.startswith("variant:"):
        return f"variant-{Path(condition.removeprefix('variant:')).stem}"
    return condition
