"""Exercise real file replacement, launch acknowledgement, and rollback in scratch folders."""
from pathlib import Path
import subprocess
import sys
root, scratch = map(Path, sys.argv[1:])
helper = root / 'macOS App/install-update.sh'
for mode in ['success','launch-failure','startup-failure']:
    case = scratch / mode
    case.mkdir()
    target, candidate, backup = [case / name for name in ['App with spaces.app','Candidate.app','Previous.app']]
    for path, value in [(target,'old'),(candidate,'new')]:
        path.mkdir(); (path/'version').write_text(value)
    opener = case/'open'
    opener.write_text('''#!/bin/sh
case "$(cat "$2/version")" in
old) exit 0;;
new)
''' + {'success':'touch "$5"; exit 0','launch-failure':'exit 1','startup-failure':'exit 0'}[mode] + '\n;;\nesac\n')
    opener.chmod(0o755)
    result = subprocess.run(['/bin/sh',str(helper),'99999999',str(target),str(candidate),str(backup),str(case/'log'),str(case/'ack'),str(opener),'1'])
    assert (target/'version').read_text() == ('new' if mode == 'success' else 'old'), mode
    assert result.returncode == (0 if mode == 'success' else 1), mode
    if mode == 'success':
        assert (backup/'version').read_text() == 'old'
print('PASS replacement helper: paths with spaces, successful restart, failed launch rollback, failed startup rollback')

if (scratch / 'swift-catalog.json').exists():
    import importlib.util
    import json
    spec = importlib.util.spec_from_file_location('builder', root / 'build_catalog.py')
    builder = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(builder)
    expected = builder.compile_catalog({name:(scratch/name).read_text(encoding='utf-8-sig') for name in builder.FILES}, '2026-11-24')
    actual = json.loads((scratch / 'swift-catalog.json').read_text())
    assert actual['shows'] == expected['shows'], 'Swift importer differs from the established Python importer'
    print('PASS all live imported shows match the established Python importer')
