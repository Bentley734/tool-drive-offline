"""Check the offline distribution contract without network access or extra packages."""
import json
import math
from datetime import date
from html.parser import HTMLParser
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent


class PageAudit(HTMLParser):
    def handle_starttag(self, tag, attrs):
        if tag in {"audio", "video", "iframe", "object", "embed"}:
            raise AssertionError("Unexpected media element: " + tag)
        if any(key in {"src", "href", "srcset"} for key, _ in attrs):
            raise AssertionError("Unexpected external asset or link: " + tag)


def main():
    catalog = json.loads((ROOT / "catalog.json").read_text(encoding="utf-8"))
    date.fromisoformat(catalog["snapshotDate"])
    ids = set()
    for show in catalog["shows"]:
        assert show["id"] not in ids, "Duplicate show ID"
        ids.add(show["id"])
        date.fromisoformat(show["date"])
        for source in show["sources"]:
            rating = source["rating"]
            assert rating is None or (math.isfinite(rating) and 0 < rating <= 10), "Invalid sound rating"
    assert not re.search(r"https?://|www\.|driveUrl", json.dumps(catalog), re.I), "URL in exported metadata"
    html = (ROOT / "index.html").read_text(encoding="utf-8")
    PageAudit().feed(html)
    assert not re.search(r"https?://|www\.|\bfetch\s*\(|XMLHttpRequest|WebSocket", html, re.I), "Network reference in offline HTML"
    assert "connect-src 'none'" in html and "media-src 'none'" in html, "Missing offline page restrictions"
    marker = "window.CATALOG = "
    assert html.count(marker) == 1, "Expected one embedded catalog"
    embedded, _ = json.JSONDecoder().raw_decode(html.split(marker, 1)[1])
    assert embedded == catalog, "HTML and native catalogs differ"
    print("PASS offline distribution: {} shows, no external assets, audio, or network links".format(len(ids)))


if __name__ == "__main__":
    main()
