#!/usr/bin/env python3
"""Slugify a free-form topic into an AMQ session name.

AMQ accepts only [a-z0-9_-] for session names. Cyrillic is transliterated
rather than dropped: stripping it would collapse a Russian topic name into
an empty string and the session would never be created.

Source letters are escapes on purpose: this file gets vendored into other
people's repositories, where literal Cyrillic that looks like Latin trips
"ambiguous character" lint rules, and a noqa would only trade one warning
for another. The keys run in alphabetical order, a-ya, then the Ukrainian
additions.
"""

import hashlib
import re
import sys

CYRILLIC = {
    "\u0430": "a",
    "\u0431": "b",
    "\u0432": "v",
    "\u0433": "g",
    "\u0434": "d",
    "\u0435": "e",
    "\u0451": "e",
    "\u0436": "zh",
    "\u0437": "z",
    "\u0438": "i",
    "\u0439": "y",
    "\u043a": "k",
    "\u043b": "l",
    "\u043c": "m",
    "\u043d": "n",
    "\u043e": "o",
    "\u043f": "p",
    "\u0440": "r",
    "\u0441": "s",
    "\u0442": "t",
    "\u0443": "u",
    "\u0444": "f",
    "\u0445": "h",
    "\u0446": "c",
    "\u0447": "ch",
    "\u0448": "sh",
    "\u0449": "sch",
    "\u044a": "",
    "\u044b": "y",
    "\u044c": "",
    "\u044d": "e",
    "\u044e": "yu",
    "\u044f": "ya",
    "\u0456": "i",
    "\u0457": "yi",
    "\u0454": "e",
    "\u0491": "g",
}

MAX_LEN = 60


def slug(raw: str, maxlen: int = MAX_LEN) -> str:
    """Return a canonical AMQ session name for an arbitrary topic string."""
    text = (raw or "").strip().lower()
    text = "".join(CYRILLIC.get(char, char) for char in text)
    text = re.sub(r"[^a-z0-9_-]+", "-", text).strip("-")
    text = re.sub(r"-{2,}", "-", text)
    digest = hashlib.sha256((raw or "").encode()).hexdigest()
    if len(text) > maxlen:
        # Keep it recognisable but bounded, and still unique per input. The
        # hash counts towards the budget: a name that has to be dictated to a
        # neighbour as --session should not overrun what was asked for.
        text = text[: maxlen - 7].rstrip("-") + "-" + digest[:6]
    if not text:
        # Nothing survived: emoji, CJK or punctuation only.
        text = "t-" + digest[:8]
    return text


def main() -> None:
    """Print the slug for the first argument."""
    sys.stdout.write(slug(sys.argv[1] if len(sys.argv) > 1 else "") + "\n")


if __name__ == "__main__":
    main()
