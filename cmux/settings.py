#!/usr/bin/env python3
"""settings.py — add the cockpit's cmux settings to ~/.config/cmux/cmux.json.

    python3 settings.py <cmux.json>    add what is missing; print one line per group added

Settings come in groups (below). A group is added only when none of its keys is set
yet, so a choice you made yourself, either way, is never replaced. cmux.json is JSONC:
keys are added as new lines, so comments and formatting stay as they are, and the
result must parse before it is written.
"""
import json
import re
import sys

GROUPS = [
    ("workspaces move to the top on agent activity", {
        "app.reorderOnNotification": "agentActivity",
    }),
    # cmux's own sound stays silent while cmux is the active app (manaflow-ai/cmux#2801);
    # afplay works, so it plays every notification's sound and cmux's is switched off.
    # The two only make sense together.
    ("notification sound: Frog, also while cmux is in front", {
        "notifications.sound": "none",
        "notifications.command": "afplay -v 3 /System/Library/Sounds/Frog.aiff",
        "notifications.soundWhenFocused": True,
    }),
]


def strip_comments(src):
    """JSONC -> JSON: drop // and /* */ comments outside strings, and trailing commas."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
            out.append(src[i:j + 1]); i = j + 1
        elif src.startswith("//", i):
            while i < n and src[i] != "\n":
                i += 1
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
        else:
            out.append(c); i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def has(data, dotted):
    for part in dotted.split("."):
        if not isinstance(data, dict) or part not in data:
            return False
        data = data[part]
    return True


def add(src, section, key, value):
    """Insert "key": value as the first line of the top-level section, or add the section."""
    line = json.dumps(key) + ": " + json.dumps(value)
    top = re.search(r'(?m)^( *)"schemaVersion"\s*:[^\n]*\n', src)
    if not top:
        raise ValueError("no schemaVersion line to add the section after")
    # only a top-level section: same indent as schemaVersion
    m = re.search(r'(?m)^' + top.group(1) + r'"' + re.escape(section) + r'"\s*:\s*\{[ \t]*\n', src)
    if m:
        rest = src[m.end():]
        empty = re.match(r"\s*\}", rest) is not None
        indent = top.group(1) + "  "
        return src[:m.end()] + indent + line + ("" if empty else ",") + "\n" + rest
    indent = top.group(1)
    head = src[:top.end()]
    if not re.search(r",\s*(//[^\n]*)?\n$", head):         # schemaVersion was the last property
        head = re.sub(r"\s*(//[^\n]*)?\n$", lambda c: "," + (" " + c.group(1) if c.group(1) else "") + "\n", head)
    block = "\n%s%s: {\n%s  %s\n%s},\n" % (indent, json.dumps(section), indent, line, indent)
    return head + block + src[top.end():]


def main(path):
    with open(path) as f:
        src = f.read()
    data = json.loads(strip_comments(src))
    added, keys = [], []
    for label, settings in GROUPS:
        if any(has(data, k) for k in settings):
            continue
        for dotted, value in settings.items():
            section, key = dotted.split(".", 1)
            src = add(src, section, key, value)
        added.append(label); keys += list(settings)
    if not added:
        return 0
    new = json.loads(strip_comments(src))           # never write a file that does not parse
    if not all(has(new, k) for k in keys):
        raise ValueError("a setting did not land")
    with open(path + ".vicks-settings-backup", "w") as f:
        with open(path) as orig:
            f.write(orig.read())
    with open(path, "w") as f:
        f.write(src)
    for label in added:
        print("cmux: " + label)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1]))
    except (OSError, ValueError) as e:
        print("cmux settings not added: %s" % e, file=sys.stderr)
        sys.exit(0)
