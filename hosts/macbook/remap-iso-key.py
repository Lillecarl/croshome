#!/usr/bin/env python3
"""Make virtual key 10 (Apple's ISO "section" key) output whatever virtual
key 50 (grave/tilde) outputs, for every modifier combination, in each given
.keylayout file. See the comment above the postPatch call in eurkey.nix.

This is regex, not a real XML parser, on purpose. These files declare
<?xml version="1.1"?> and rely on XML 1.1's wider character-reference range
for entries like `output="&#x0008;"` (backspace). Neither xml.etree
(expat) nor lxml (libxml2) actually implements XML 1.1 -- both are XML 1.0
parsers underneath and raise ParseError/XMLSyntaxError on this file. Do not
"fix" this into ElementTree or lxml; it has been tried and it does not
parse. The regex stays narrow instead: it only matches self-closing
<key code="10"/> and <key code="50"/> elements inside one named
<keyMapSet>, with no nesting to worry about.
"""
import re
import sys

KEY_MAP_SET = re.compile(r'<keyMapSet id="16c">.*?</keyMapSet>', re.S)
KEY_MAP = re.compile(r'<keyMap index="\d+">.*?</keyMap>', re.S)
KEY_10 = re.compile(r'<key code="10"[^/]*/>')
KEY_50 = re.compile(r'<key code="50"[^/]*/>')


def patch_key_map(match: re.Match) -> str:
    body = match.group(0)
    match_50 = KEY_50.search(body)
    match_10 = KEY_10.search(body)
    if not match_50 or not match_10:
        return body
    new_10 = match_50.group(0).replace('code="50"', 'code="10"')
    return body[: match_10.start()] + new_10 + body[match_10.end() :]


def patch_key_map_set(match: re.Match) -> str:
    return KEY_MAP.sub(patch_key_map, match.group(0))


for path in sys.argv[1:]:
    with open(path) as f:
        text = f.read()
    with open(path, "w") as f:
        f.write(KEY_MAP_SET.sub(patch_key_map_set, text))
