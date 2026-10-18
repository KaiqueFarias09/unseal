#!/usr/bin/env python3
"""Run pinned DjVuLibre reference and D04 comparisons, including negative controls.

DART_BIN points at a Dart SDK, DJVU_SOURCE at official 3.5.29 headers and
DJVU_LIB at the installed library directory. Outputs always stay in build/.
Usage: python3 tool/djvu_fgbz_evidence.py reference|compare
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/review-d04'
OUT.mkdir(parents=True, exist_ok=True)
DART = os.environ.get('DART_BIN', 'dart')
SOURCE = Path(os.environ.get('DJVU_SOURCE', ROOT / 'build/oracle/sources/djvulibre-3.5.29'))
CORPUS = [ROOT / 'test/resources/djvu' / name for name in ('navm-fgbz.djvu', 'spec-bundled.djvu')]
CORPUS += sorted((ROOT / 'test/resources/djvu/derived').glob('fgbz-*.djvu'))
CORPUS = [p for p in CORPUS if p.name != 'fgbz-budget-page.djvu']
HISTORY = []

def run(argv, name, expected=0):
    begin = time.monotonic()
    result = subprocess.run([str(x) for x in argv], cwd=ROOT, capture_output=True, timeout=600)
    target = OUT / (name + '.log')
    target.write_bytes(result.stdout + result.stderr)
    HISTORY.append({'argv': [str(x) for x in argv], 'exitCode': result.returncode,
                    'seconds': round(time.monotonic()-begin, 3), 'log': str(target.relative_to(ROOT))})
    if (result.returncode == 0) != (expected == 0):
        raise RuntimeError(f'{name}: unexpected exit {result.returncode}: {target}')
    return result

def write(name, value):
    (OUT/name).write_text(json.dumps(value, indent=2) + '\n')

def version():
    version = run(['ddjvu', '--help'], 'version', expected=1)
    if b'DjVuLibre-3.5.29' not in version.stdout + version.stderr:
        raise RuntimeError('Reference is not pinned DjVuLibre 3.5.29')
    print('DjVuLibre 3.5.29 verified')

def reference():
    version()
    run(['c++', '-std=c++17', '-O2', '-DHAVE_CONFIG_H', '-I'+str(SOURCE), '-I'+str(SOURCE/'libdjvu'),
         'tool/djvu_fgbz_oracle.cpp', '-o', OUT/'native', '-L'+os.environ.get('DJVU_LIB','/opt/homebrew/lib'),
         '-ldjvulibre'], 'compile-native')
    docs=[]
    for number, path in enumerate(CORPUS):
        run(['djvudump', path], f'dump-{number}')
        run(['djvused', path, '-e', 'n'], f'pages-{number}')
        run([OUT/'native', path, OUT], f'native-{number}')
        native = OUT/(path.name+'.fgbz-oracle.json')
        data=json.loads(native.read_text())
        if data.get('djvulibre') != 'DjVuLibre-3.5.29':
            raise RuntimeError('Native helper linked an unexpected library version')
        # Every page is checked structurally. The foreground lane requires all
        # FGbz pages plus the first non-FGbz control page of each document.
        for page in data['pages']:
            if page.get('fgbz') is not None or page['page']==1:
                run(['ddjvu', '-format=ppm', '-mode=foreground', '-page='+str(page['page']), path,
                     OUT/f"{path.stem}-p{page['page']}-foreground.ppm"], f'foreground-{number}-{page["page"]}')
        docs.append({'file': str(path.relative_to(ROOT)), 'native': str(native.relative_to(ROOT)),
                     'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'pages': len(data['pages'])})
    write('reference.json', {'pin':'DjVuLibre 3.5.29', 'documents':docs, 'commands':HISTORY})

def compare():
    reference=json.loads((OUT/'reference.json').read_text())
    reports=[]
    for number, doc in enumerate(reference['documents']):
        report=OUT/f'comparison-{number}.json'
        run([DART,'run','tool/djvu_fgbz_compare.dart',doc['file'],doc['native'],OUT,'--out',report], f'compare-{number}')
        data=json.loads(report.read_text())
        if not data['pass'] or not data['pages']:
            raise RuntimeError('Empty or failed semantic comparison')
        reports.append(str(report.relative_to(ROOT)))
    valid=next(d for d in reference['documents'] if d['file'].endswith('fgbz-repeat-colors.djvu'))
    native=json.loads((ROOT/valid['native']).read_text())
    for mutation in ('palette','index','blit','shape','bitmap','empty'):
        altered=copy.deepcopy(native)
        page=altered['pages'][0]
        if mutation=='palette': page['fgbz']['palette'][0][0] ^= 1
        if mutation=='index': page['fgbz']['colordata'][0] = 1
        if mutation=='blit': page['sjbz']['blits'][0]['left'] += 1
        if mutation=='shape': page['sjbz']['blits'][0]['shape'] += 1
        if mutation=='bitmap': page['sjbz']['blits'][0]['bits'] = '00'
        if mutation=='empty': altered['pages'] = []
        target=OUT/f'negative-{mutation}.json'; target.write_text(json.dumps(altered))
        run([DART,'run','tool/djvu_fgbz_compare.dart',valid['file'],target,OUT], f'negative-{mutation}', expected=1)
    run([DART,'run','tool/djvu_fgbz_compare.dart',valid['file'],OUT/'missing-reference.json',OUT], 'negative-missing-reference',expected=1)
    ppm=OUT/'fgbz-repeat-colors-p1-foreground.ppm'
    hidden=ppm.with_suffix('.hold'); ppm.rename(hidden)
    try:
        run([DART,'run','tool/djvu_fgbz_compare.dart',valid['file'],valid['native'],OUT], 'negative-missing-raster',expected=1)
    finally: hidden.rename(ppm)
    run([OUT/'native', OUT/'nonexistent.djvu', OUT], 'negative-command-failure',expected=1)
    run(['/usr/bin/time','-l',DART,'test','test/tests/djvu/'], 'vm-focused-rss')
    run([DART,'compile','js','web/unseal_worker.dart','-o','test/web/unseal_worker.js'], 'compile-worker')
    run([DART,'test','-p','chrome','test/web/djvu_fgbz_worker_test.dart','test/web/djvu_wire_test.dart'], 'chrome')
    # Artifacts are refreshed by this comparison stage; the gate verifies their hashes.
    evidence=reports+['build/review-d04/vm-focused-rss.log','build/review-d04/chrome.log']
    write('comparison.json', {'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
          'cases':[{'id':f'DC{i:02}', 'verdict':'pass','evidenceArtifacts':evidence,
                    'evidence':{'nativeDocuments':len(reports),'commands':HISTORY}} for i in range(1,9)]})

if len(sys.argv)!=2 or sys.argv[1] not in ('version','reference','compare'):
    raise SystemExit('Expected version, reference or compare')
{'version':version, 'reference':reference, 'compare':compare}[sys.argv[1]]()
