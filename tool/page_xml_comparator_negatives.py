#!/usr/bin/env python3
"""Execute the PAGE comparator's deliberately invalid reference cases."""
import argparse
import json
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root', type=Path, default=Path('build/c02'))
parser.add_argument('--dart', default='dart')
args = parser.parse_args()
out = args.root.resolve() / 'outputs'
out.mkdir(parents=True, exist_ok=True)
base = [args.dart, 'run', 'tool/page_xml_compare.dart', '--inputs', str(args.root)]
results = {}
for name in ('missing', 'divergent', 'empty'):
    reference = out / (name + '-reference.json')
    if name == 'missing':
        reference.unlink(missing_ok=True)
    else:
        mutated = json.loads((out / 'reference.json').read_text())
        if name == 'divergent':
            document = next(value for key, value in mutated['documents'].items() if not key.startswith('negative-'))
            document['metadata']['creator'] = 'DELIBERATE COMPARATOR MUTATION'
        else:
            mutated['documents'] = {}
        reference.write_text(json.dumps(mutated))
    argv = base + ['--reference', str(reference), '--out', str(out / (name + '-comparison.json'))]
    result = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    (out / (name + '.log')).write_text('argv: ' + repr(argv) + '\nexit: ' + str(result.returncode) + '\n' + result.stdout + result.stderr)
    results[name] = result.returncode != 0
argv = [sys.executable, 'tool/page_xml_reference.py', '--root', str(out / 'missing-inputs')]
result = subprocess.run(argv, capture_output=True, text=True, timeout=120)
(out / 'failed-reference-command.log').write_text('argv: ' + repr(argv) + '\nexit: ' + str(result.returncode) + '\n' + result.stdout + result.stderr)
results['failedReferenceCommand'] = result.returncode != 0
(out / 'comparator-negatives.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps(results))
raise SystemExit(0 if all(results.values()) else 1)
