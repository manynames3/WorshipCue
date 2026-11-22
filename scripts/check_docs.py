#!/usr/bin/env python3
"""Check that relative Markdown links and in-repository anchors resolve.

External URLs and links to other branches are not fetched. Standard library only.
"""
from __future__ import annotations

import re
import sys
import unicodedata
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
SKIP_DIRS = {'.git', '.build', '.swiftpm', 'node_modules', 'DerivedData'}
LINK = re.compile(r'(?:\]\(|href="|src=")([^)"\s]+)')
HEADING = re.compile(r'^ {0,3}#{1,6}\s+(.+?)\s*#*\s*$')
FENCE = re.compile(r'^ {0,3}(```|~~~)')


def slug(heading: str) -> str:
    """GitHub-style heading anchor."""
    text = re.sub(r'`([^`]*)`', r'\1', heading)
    text = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', text)
    text = re.sub(r'<[^>]+>', '', text).strip().lower()
    kept = ''.join(ch for ch in text
                   if ch in ' -_' or unicodedata.category(ch)[0] in 'LNM')
    return kept.replace(' ', '-')


def markdown_lines(path: Path) -> list[str]:
    lines, fenced = [], False
    for line in path.read_text(encoding='utf-8').splitlines():
        if FENCE.match(line):
            fenced = not fenced
            continue
        if not fenced:
            lines.append(line)
    return lines


def anchors(path: Path) -> set[str]:
    found: set[str] = set()
    counts: dict[str, int] = {}
    for line in markdown_lines(path):
        match = HEADING.match(line)
        if not match:
            continue
        base = slug(match.group(1))
        index = counts.get(base, 0)
        counts[base] = index + 1
        found.add(base if index == 0 else f'{base}-{index}')
    return found


def main() -> int:
    documents = [p for p in ROOT.rglob('*.md')
                 if not SKIP_DIRS.intersection(p.relative_to(ROOT).parts)]
    cache: dict[Path, set[str]] = {}
    failures = checked = 0
    for document in sorted(documents):
        for line in markdown_lines(document):
            for match in LINK.finditer(re.sub(r'`[^`]*`', '', line)):
                target = match.group(1)
                if re.match(r'^[a-z][a-z0-9+.-]*:', target, re.I):
                    continue  # http(s), mailto and other external schemes
                path_part, _, fragment = target.partition('#')
                destination = (document.parent / unquote(path_part)).resolve() if path_part else document
                checked += 1
                problem = None
                if not destination.exists():
                    problem = 'missing file'
                elif fragment and destination.suffix == '.md':
                    known = cache.setdefault(destination, anchors(destination))
                    if unquote(fragment).lower() not in known:
                        problem = f'missing anchor #{fragment}'
                if problem:
                    failures += 1
                    print(f'FAIL {document.relative_to(ROOT)} -> {target}: {problem}')
    print(f'{checked} relative links checked in {len(documents)} Markdown files; {failures} broken')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
