"""Build a Chromium extension from Catppuccin's userstyles.

    build.py <userstyles> <remote css> <flavor> <accent> <here> <out>

<remote css> holds each stylesheet the styles import, named by the sha256 of
its URL. <here> holds apply.js and background.js.
"""

from __future__ import annotations

import concurrent.futures
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Iterator

HEADER = re.compile(r"/\* ==UserStyle==.*?==/UserStyle== \*/", re.DOTALL)
VAR = re.compile(r'^@var\s+(\w+)\s+([\w-]+)\s+"[^"]*"\s+(.*)$', re.MULTILINE)
LIBRARY = re.compile(r'@import\s+"https://userstyles\.catppuccin\.com/lib/([^"]+)"\s*;')
REMOTE = re.compile(r'@import\s+(?:\(css\)\s*)?url\("([^"]+)"\)([^;]*);')
KEPT = re.compile(r"/\*!remote (\S+) (.*?)\*/")
RULE = re.compile(r'(domain|url-prefix|url|regexp)\(\s*"((?:[^"\\]|\\.)*)"\s*\)')
DOCUMENT = "@-moz-document"
COMPLETE_HOST = re.compile(
    r"\^?https?\??:\\?/\\?/(?:\(www\\?\.\)\?)?([a-z0-9-]+(?:\\?\.[a-z0-9-]+)+)(?=[/(:$\\]|$)"
)
ADDRESS = re.compile(r"[\d.]+")


@dataclass(frozen=True, slots=True)
class Rule:
    kind: str
    value: str


@dataclass(frozen=True, slots=True)
class Section:
    rules: tuple[Rule, ...]
    css: str


def default_of(kind: str, spec: str) -> str:
    """Return a @var's own default, as Less source."""
    match kind:
        case "select":
            options: list[str] = json.loads(spec)
            chosen = next((each for each in options if each.endswith("*")), options[0])
            return chosen.split(":")[0].rstrip("*")
        case "range" | "number":
            parts = [each.strip() for each in spec.strip("[]").split(",")]
            unit = next((each.strip("'\"") for each in parts if each[:1] in "'\""), "")
            return parts[0] + unit
        case _:
            return spec.strip()


def variables(header: str, flavor: str, accent: str) -> dict[str, str]:
    chosen = {"lightFlavor": flavor, "darkFlavor": flavor, "accentColor": accent}
    return {
        name: chosen.get(name) or default_of(kind, spec)
        for kind, name, spec in VAR.findall(header)
    }


def local(source: str, library: Path) -> str:
    return LIBRARY.sub(lambda found: f'@import "{library / found[1]}";', source)


def copied(library: Path, to: Path) -> Path:
    """Copy the library, whose files import each other from the web."""
    for path in library.rglob("*.less"):
        copy = to / path.relative_to(library)
        copy.parent.mkdir(parents=True, exist_ok=True)
        copy.write_text(local(path.read_text(), to))
    return to


def compiled(source: str, values: dict[str, str], library: Path) -> str:
    """Compile Less to CSS, remote imports kept in place for `inlined`."""

    def kept(found: re.Match[str]) -> str:
        url = re.sub(r"@\{([\w-]+)\}", lambda name: values[name[1]], found[1])
        return f"/*!remote {url} {found[2].strip()}*/"

    source = REMOTE.sub(kept, local(source, library))
    prelude = "".join(f"@{name}: {value};\n" for name, value in values.items())
    done = subprocess.run(
        ["lessc", "-"],
        input=prelude + source,
        capture_output=True,
        text=True,
        check=False,
    )
    if done.returncode != 0:
        raise RuntimeError(done.stderr)
    return done.stdout


def inlined(css: str, remote: Path) -> str:
    def content(found: re.Match[str]) -> str:
        sheet = (remote / hashlib.sha256(found[1].encode()).hexdigest()).read_text()
        media = found[2].strip()
        return f"@media {media} {{\n{sheet}\n}}" if media else sheet

    return KEPT.sub(content, css)


def skip(css: str, at: int) -> int:
    """Return where the string or comment that starts at `at` ends, or `at`."""
    if css.startswith("/*", at):
        return css.index("*/", at) + 2
    if css[at] in "\"'":
        quote, end = css[at], at + 1
        while css[end] != quote:
            end += 2 if css[end] == "\\" else 1
        return end + 1
    return at


def braces(css: str, at: int) -> int:
    """Return where the block whose `{` is at `at` ends."""
    depth = 0
    while True:
        after = skip(css, at)
        if after != at:
            at = after
            continue
        if css[at] == "{":
            depth += 1
        elif css[at] == "}":
            depth -= 1
            if depth == 0:
                return at
        at += 1


def opening(css: str, at: int) -> int:
    while css[at] != "{":
        at = max(at + 1, skip(css, at))
    return at


def sections(css: str) -> Iterator[Section]:
    at = css.find(DOCUMENT)
    while at != -1:
        start = opening(css, at)
        end = braces(css, start)
        rules = tuple(
            # A CSS string's escapes.
            Rule(kind, re.sub(r"\\(.)", r"\1", value))
            for kind, value in RULE.findall(css[at:start])
        )
        if not rules:
            raise ValueError(f"no rules in {css[at:start]!r}")
        yield Section(rules, css[start + 1 : end].strip())
        at = css.find(DOCUMENT, end)


def hosts(rule: Rule) -> list[str] | None:
    """Return match patterns holding every page of `rule`, or None for none known."""
    match rule.kind:
        case "domain":
            host = rule.value
        case "url" | "url-prefix":
            # Another extension's pages, which no content script runs in.
            if not rule.value.startswith(("http://", "https://")):
                return []
            host = rule.value.split("://")[-1].split("/")[0].split(":")[0]
        case _:
            found = COMPLETE_HOST.match(rule.value)
            if found is None:
                return None
            host = found[1].replace("\\", "")
    if ADDRESS.fullmatch(host):
        return [f"*://{host}/*"]
    return [f"*://{host}/*", f"*://*.{host}/*"]


def words(rule: Rule) -> list[str]:
    return [
        each
        for each in re.findall(r"[a-z0-9-]{4,}", rule.value)
        if each not in {"http", "https"}
    ]


def scripts(name: str, style: list[Section]) -> Iterator[dict[str, object]]:
    """Yield the manifest's content_scripts entries, which are arbitrary JSON."""
    every = [rule for section in style for rule in section.rules]
    known = sorted({each for rule in every for each in hosts(rule) or ()})
    globs = sorted(
        {f"*{each}*" for rule in every if hosts(rule) is None for each in words(rule)}
    )
    common = {
        "js": ["apply.js", f"styles/{name}.js"],
        "run_at": "document_start",
        "all_frames": True,
    }
    if known:
        yield {"matches": known, **common}
    if globs:
        yield {"matches": ["*://*/*"], "include_globs": globs, **common}


def build(
    style: Path, remote: Path, flavor: str, accent: str, library: Path
) -> list[Section]:
    source = style.read_text()
    header = HEADER.search(source)
    if header is None:
        raise ValueError(f"{style} has no header")
    values = variables(header[0], flavor, accent)
    css = compiled(source[header.end() :], values, library)
    return list(sections(inlined(css, remote)))


def main() -> None:
    userstyles, remote, here, out = (Path(sys.argv[each]) for each in (1, 2, 5, 6))
    flavor, accent = sys.argv[3], sys.argv[4]
    (out / "styles").mkdir(parents=True)
    for each in ("apply.js", "background.js"):
        shutil.copy(here / each, out / each)

    entries: list[dict[str, object]] = []
    found = sorted(userstyles.glob("styles/*/catppuccin.user.less"))
    with (
        tempfile.TemporaryDirectory() as work,
        concurrent.futures.ThreadPoolExecutor(os.cpu_count()) as pool,
    ):
        library = copied(userstyles / "lib", Path(work))
        done = pool.map(
            lambda style: build(style, remote, flavor, accent, library),
            found,
        )
        for path, style in zip(found, done, strict=True):
            name = path.parent.name
            payload = json.dumps(
                [
                    {
                        "rules": [[rule.kind, rule.value] for rule in each.rules],
                        "css": each.css,
                    }
                    for each in style
                ]
            )
            (out / "styles" / f"{name}.js").write_text(
                f"catppuccin({json.dumps(name)}, {payload});\n"
            )
            entries.extend(scripts(name, style))

    (out / "manifest.json").write_text(
        json.dumps(
            {
                "manifest_version": 3,
                "name": f"Catppuccin {flavor.capitalize()}",
                "description": "Catppuccin's userstyles. Click to turn them off on a site.",
                "version": "1.0",
                "permissions": ["storage", "activeTab"],
                "action": {"default_title": "Catppuccin on this site"},
                "background": {"service_worker": "background.js"},
                "content_scripts": entries,
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
