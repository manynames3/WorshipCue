#!/usr/bin/env python3
"""Opt-in physical-iPad tests. All supplied charts/results stay outside Git."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pdf_a', type=Path)
    parser.add_argument('pdf_b', type=Path)
    parser.add_argument('--native-only', action='store_true', help='Verify the real PDFs and collect native renders without starting UI automation')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    tools = Path(os.environ.get('WORSHIPCUE_TOOLS_ROOT', repo.parent / 'DeveloperTools')).resolve()
    # Prevent private inputs/results from becoming repository artifacts.
    if tools == repo or repo in tools.parents:
        parser.error('WORSHIPCUE_TOOLS_ROOT must be outside the repository')
    device = os.environ.get('WORSHIPCUE_TEST_DEVICE_ID')
    team = os.environ.get('WORSHIPCUE_TEST_TEAM_ID')
    if not device or not team:
        parser.error('Supply discovered WORSHIPCUE_TEST_DEVICE_ID and authorized WORSHIPCUE_TEST_TEAM_ID privately')
    run_id = str(uuid.uuid4()).upper()
    output = tools / 'WorshipCue' / 'PrivateChartTests' / run_id
    inputs = output / 'Inputs'
    inputs.mkdir(parents=True)
    for label, source in [('A', args.pdf_a), ('B', args.pdf_b)]:
        source = source.resolve(strict=True)
        if repo in source.parents:
            parser.error('Private charts must be outside the repository')
        with source.open('rb') as stream:
            if b'%PDF-' not in stream.read(1024):
                parser.error('Each input must be a PDF')
        shutil.copy2(source, inputs / f'arrangement-{label}.pdf')
    wrapper = ['sh', str(repo / 'scripts/with_external_xcode.sh')]

    def execute(label, command):
        with (output / f'{label}.log').open('wb') as log:
            try:
                code = subprocess.run(wrapper + command, cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=900).returncode
            except subprocess.TimeoutExpired:
                code = 124
        print(f'{label}: exit {code}', flush=True)
        if code:
            print(f'NOT VERIFIED: stopped at {label}. Private logs: {output}', flush=True)
            raise SystemExit(code)

    print(f'Private results: {output}', flush=True)
    execute('stage', ['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', device,
                     '--source', str(inputs), '--destination', f'Documents/WorshipCuePrivateTests/{run_id}',
                     '--domain-type', 'appDataContainer', '--domain-identifier', 'com.worshipcue.spike',
                     '--timeout', '45'])
    derived = tools / 'WorshipCue/DerivedData-Xcode27-iPad17'
    execute('build', ['xcodebuild', '-project', 'apps/ipad/WorshipCue.xcodeproj', '-scheme', 'WorshipCueUI',
                     '-configuration', 'Debug', '-derivedDataPath', str(derived),
                     '-clonedSourcePackagesDirPath', str(tools / 'WorshipCue/SourcePackages'),
                     '-destination', f'platform=iOS,id={device}', '-destination-timeout', '30',
                     f'SDK_STAT_CACHE_DIR={derived}', f'DEVELOPMENT_TEAM={team}', 'CODE_SIGN_STYLE=Automatic',
                     '-allowProvisioningUpdates', '-parallel-testing-enabled', 'NO', 'build-for-testing'])
    templates = list((derived / 'Build/Products').glob('WorshipCueUI_*.xctestrun'))
    if not templates:
        raise RuntimeError('Xcode did not produce a WorshipCueUI test run')
    template = max(templates, key=lambda p: p.stat().st_mtime)
    config = plistlib.loads(template.read_bytes())
    targets = []
    for test_config in config.get('TestConfigurations', []):
        targets.extend(test_config.get('TestTargets', []))
    if not targets:  # Older xctestrun format.
        targets = [value for key, value in config.items() if not key.startswith('__') and isinstance(value, dict)]
    for target in targets:
        target.setdefault('EnvironmentVariables', {})['WORSHIPCUE_PRIVATE_PDF_RUN'] = run_id
    # __TESTROOT__ paths are relative to the xctestrun's directory.
    configured = template.parent / f'WorshipCuePrivate-{run_id}.xctestrun'
    configured.write_bytes(plistlib.dumps(config))
    shutil.copy2(configured, output / 'configured.xctestrun')
    results = {'run': run_id, 'commands': {}, 'public_artifacts': False}
    cases = [
        ('native', 'WorshipCueTests/NativeInkTests/testPrivatePDFPairPreservesAnnotationsAndManualTransferAcrossDifferentGeometry'),
    ]
    if not args.native_only:
        cases.append(('ui', 'WorshipCueUITests/MusicStandUITests/testPrivatePDFPairFingerInkSelectedTransferAndColdRelaunch'))
    for label, case in cases:
        bundle = output / f'{label}.xcresult'
        execute(label, ['xcodebuild', 'test-without-building', '-xctestrun', str(configured),
                        '-destination', f'platform=iOS,id={device}', '-destination-timeout', '30',
                        '-parallel-testing-enabled', 'NO', '-only-testing:' + case,
                        '-collect-test-diagnostics', 'never', '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '180',
                        '-resultBundlePath', str(bundle)])
        summary = subprocess.check_output(wrapper + ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                                                    '--path', str(bundle)], cwd=repo)
        report = json.loads(summary)
        (output / f'{label}-summary.json').write_bytes(summary)
        if report.get('passedTests') != 1 or report.get('failedTests') != 0 or report.get('skippedTests') != 0:
            raise RuntimeError(f'{label} did not execute and pass its one required case')
        results['commands'][label] = {'passed': 1, 'failed': 0, 'skipped': 0}
    execute('collect-renders', ['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', device,
                               '--source', f'Documents/WorshipCuePrivateTests/{run_id}/PDFKitRenders',
                               '--destination', str(output / 'PDFKitRenders'), '--domain-type', 'appDataContainer',
                               '--domain-identifier', 'com.worshipcue.spike', '--timeout', '45'])
    (output / 'result.json').write_text(json.dumps(results, indent=2) + '\n')
    print('PASS: private native import/annotation/transfer/export check' + ('; UI not run (--native-only)' if args.native_only else ' and physical finger UI workflow'), flush=True)
    print('Physical Apple Pencil and older-iPad qualification remain NOT VERIFIED.', flush=True)


if __name__ == '__main__':
    main()
