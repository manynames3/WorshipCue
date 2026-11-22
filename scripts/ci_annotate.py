#!/usr/bin/env python3
"""Turn compiler and XCTest failures in an xcodebuild log into GitHub annotations.

Usage: ci_annotate.py LOG. Prints nothing for a clean log. Standard library only.
"""
from __future__ import annotations

import os
import re
import sys

LOCATED = re.compile(r'^(?P<file>/[^:\n]+):(?P<line>\d+)(?::(?P<col>\d+))?: (?:fatal )?error: (?P<msg>.+)$')
GENERAL = re.compile(r'^(?:xcodebuild: )?error: (?P<msg>.+)$|^(?P<fail>\*\* [A-Z -]+ FAILED \*\*.*)$'
                     r"|^(?P<case>Test Case '.+' failed.*)$")


def escape(value: str) -> str:
    return value.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')


def escape_property(value: str) -> str:
    return escape(value).replace(':', '%3A').replace(',', '%2C')


def main(path: str) -> None:
    workspace = os.environ.get('GITHUB_WORKSPACE', os.getcwd()).rstrip('/') + '/'
    seen: set[str] = set()
    with open(path, encoding='utf-8', errors='replace') as log:
        for raw in log:
            line = raw.rstrip()
            if line in seen:
                continue
            located = LOCATED.match(line)
            general = None if located else GENERAL.match(line)
            if not located and not general:
                continue
            seen.add(line)
            if located:
                file = located['file'].removeprefix(workspace)
                print(f"::error file={escape_property(file)},line={located['line']}::{escape(located['msg'])}")
            else:
                print(f'::error::{escape(line)}')
            if len(seen) >= 40:
                break


if __name__ == '__main__':
    main(sys.argv[1])
