"""Build a single-file, metadata-only offline catalog. Python standard library only.

Rebuild from saved public metadata:
  python build_catalog.py --cache PATH
Or explicitly refresh public metadata online (never requests audio):
  python build_catalog.py --refresh
"""
import argparse
import json
from pathlib import Path
import re
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

ROOT = Path(__file__).resolve().parent
FILES = ('01-shows.js', '02-sources.js', '03-songs.js', '09-setlist-history.js')


def read_constant(text, name):
    match = re.search(r'\bconst\s+' + re.escape(name) + r'\s*=\s*', text)
    if not match:
        raise ValueError('Missing public data constant: ' + name)
    return json.JSONDecoder().raw_decode(text[match.end():])[0]


def clean(value):
    # Keep metadata text, remove every URL, including links buried in lineage notes.
    text = '' if value is None else str(value)
    return re.sub(r'(?:https?://|www\.)\S+', '[link removed]', text, flags=re.I).strip()


def rating(value):
    try:
        result = float(value)
        return result if 0 < result <= 10 else None
    except (TypeError, ValueError):
        return None


def compile_catalog(blobs, snapshot_date):
    shows = read_constant(blobs['01-shows.js'], 'SHOWS')
    sources = read_constant(blobs['02-sources.js'], 'SOURCES_DATA')
    songs = read_constant(blobs['03-songs.js'], 'SONGS')
    history = read_constant(blobs['09-setlist-history.js'], 'SETLIST_HISTORY')
    song_ids = read_constant(blobs['09-setlist-history.js'], 'SETLIST_SONG_IDS')
    titles = {s['id']: clean(s['title']) for s in songs}
    known = {}
    for song in songs:
        for show_id in song.get('appearances', []):
            known.setdefault(show_id, []).append(clean(song['title']))
    result = []
    for show in shows:
        row = {k: (show[k] if k == 'id' else clean(show.get(k)))
               for k in ('id', 'date', 'venue', 'city', 'state', 'country', 'status', 'festival')}
        row['sources'] = []
        for source in sources.get(str(show['id']), []):
            src = {'id': source['id'], 'rating': rating(source.get('rating'))}
            for target, key in (
                ('version', 'ver'), ('taper', 'taper'), ('gear', 'gear'),
                ('generation', 'generation'), ('length', 'len'), ('status', 'status'),
                ('lineage', 'lineage'), ('recordingType', 'recordingType'),
                ('codec', 'fileCodec'), ('lossless', 'fileLossless'),
            ):
                src[target] = clean(source.get(key))
            row['sources'].append(src)
        entry = history.get(show['date'], {})
        row['setlist'] = [
            {'title': titles.get(song_ids[idx], clean(song_ids[idx].replace('-', ' ').title()))}
            for idx in entry.get('s', []) if 0 <= idx < len(song_ids)
        ]
        row['setlistOmitted'] = entry.get('d', 0)
        row['tour'] = clean(entry.get('t'))
        row['songs'] = list(dict.fromkeys(known.get(show['id'], []) + [s['title'] for s in row['setlist']]))
        result.append(row)
    return {
        'snapshotDate': snapshot_date,
        'source': 'Tool Drive Project · setlists from setlist.fm',
        'ratingDescription': 'Sound quality out of 10. Source averages from the public catalog snapshot; vote counts are not available.',
        'shows': result,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, help='Directory containing the four saved public metadata files')
    parser.add_argument('--refresh', action='store_true', help='Explicitly fetch only the four public metadata files')
    parser.add_argument('--date', help='Snapshot date, YYYY-MM-DD; defaults to today in New York')
    args = parser.parse_args()
    if args.refresh == bool(args.cache):
        parser.error('Use exactly one of --cache PATH or --refresh')
    blobs = {}
    for name in FILES:
        if args.refresh:
            request = urllib.request.Request('https://tooldriveproject.net/data/' + name,
                                             headers={'User-Agent': 'ToolDriveOfflineMetadata/1.0'})
            with urllib.request.urlopen(request, timeout=30) as response:
                blobs[name] = response.read().decode('utf-8-sig')
        else:
            blobs[name] = (args.cache / name).read_text(encoding='utf-8-sig')
    try:
        today = datetime.now(ZoneInfo('America/New_York')).date()
    except ZoneInfoNotFoundError:
        # Some Windows Python installations omit the IANA timezone database.
        today = datetime.now().astimezone().date()
    snapshot_date = args.date or today.isoformat()
    catalog = compile_catalog(blobs, snapshot_date)
    serialized = json.dumps(catalog, ensure_ascii=False, separators=(',', ':'))
    # A script-closing sequence or HTML in source text must remain inert JSON data.
    embedded = serialized.replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026')
    embedded = embedded.replace('\u2028', '\\u2028').replace('\u2029', '\\u2029')
    template = (ROOT / 'app.template.html').read_text(encoding='utf-8-sig')
    marker = '/*__CATALOG_DATA__*/'
    if template.count(marker) != 1:
        raise ValueError('Expected exactly one catalog placeholder')
    html = template.replace(marker, 'window.CATALOG = ' + embedded + ';')
    if re.search(r'https?://|www\.|driveUrl|<audio\b|<video\b|<iframe\b', html, re.I):
        raise ValueError('Unexpected network URL or media reference in offline output')
    (ROOT / 'index.html').write_text(html, encoding='utf-8')
    (ROOT / 'catalog.json').write_text(serialized, encoding='utf-8')
    all_sources = [s for show in catalog['shows'] for s in show['sources'] if s['status'] != 'Unknown']
    print(json.dumps({
        'shows': len(catalog['shows']),
        'recordingSources': len(all_sources),
        'onDriveSources': sum(s['status'] == 'OTD' for s in all_sources),
        'ratedSources': sum(s['rating'] is not None for s in all_sources),
        'showsWithSetlists': sum(bool(s['setlist']) for s in catalog['shows']),
        'output': str(ROOT / 'index.html'),
        'bytes': len(html.encode('utf-8')),
    }, indent=2))


if __name__ == '__main__':
    main()
