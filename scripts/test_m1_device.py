#!/usr/bin/env python3
"""Run native M1 and UI evidence on a discovered, authorized physical iPad."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--group', choices=['native', 'ui', 'all'], default='all')
    parser.add_argument('--full-native', action='store_true', help='Include existing M0 native regressions (private PDF case skips without its inputs)')
    parser.add_argument('--regressions', action='store_true', help='Also run the four existing synthetic reader UI workflows in separate sessions')
    parser.add_argument('--only', nargs='+', choices=['native', 'workspace', 'export-ui', 'packet', 'clone', 'drawing', 'colors', 'transfer', 'team', 'team-setup', 'workspace-sources', 'v2'],
                        help='Run only selected groups; reader UI groups also require --regressions')
    parser.add_argument('--batch-ui', action='store_true', help='Run selected UI workflows in one runner; keep individual results available through --only')
    parser.add_argument('--command-timeout', type=int, help='Bound an individual command in seconds; a timeout remains a failed/unverified check')
    args = parser.parse_args()
    if args.command_timeout is not None and args.command_timeout < 1:
        parser.error('Command timeout must be positive')
    repo = Path(__file__).resolve().parents[1]
    tools = Path(os.environ.get('WORSHIPCUE_TOOLS_ROOT', repo.parent / 'DeveloperTools')).resolve()
    if tools == repo or repo in tools.parents:
        parser.error('Build and result storage must be outside the repository')
    device = os.environ.get('WORSHIPCUE_TEST_DEVICE_ID')
    team = os.environ.get('WORSHIPCUE_TEST_TEAM_ID')
    if not device or not team:
        parser.error('Supply discovered device and previously authorized signing team privately')
    output = tools / 'WorshipCue/Results' / f'M1-{uuid.uuid4()}'
    output.mkdir(parents=True)
    wrapper = ['sh', str(repo / 'scripts/with_external_xcode.sh')]
    derived = tools / 'WorshipCue/DerivedData-Xcode27-iPad17'
    print(f'M1 results: {output}', flush=True)
    results = {}

    def execute(label, command, required=False):
        with (output / f'{label}.log').open('wb') as log:
            try:
                completed = subprocess.run(wrapper + command, cwd=repo, stdout=log, stderr=subprocess.STDOUT,
                                           timeout=args.command_timeout or (1800 if label == 'ui-batch' else 900))
                code = completed.returncode
            except subprocess.TimeoutExpired:
                code = 124
        results[label] = {'exit': code}
        (output / 'results.json').write_text(json.dumps(results, indent=2))
        print(f'{label}: exit {code}', flush=True)
        if code:
            print(f'NOT VERIFIED: inspect local {label}.log and xcresult', flush=True)
            if required:
                raise SystemExit(code)
        return code

    execute('build', ['xcodebuild', '-project', 'apps/ipad/WorshipCue.xcodeproj', '-scheme', 'WorshipCueUI',
        '-configuration', 'Debug', '-derivedDataPath', str(derived), '-clonedSourcePackagesDirPath', str(tools / 'WorshipCue/SourcePackages'),
        '-destination', f'platform=iOS,id={device}', '-destination-timeout', '30', f'SDK_STAT_CACHE_DIR={derived}',
        f'DEVELOPMENT_TEAM={team}', 'CODE_SIGN_STYLE=Automatic', '-allowProvisioningUpdates',
        '-allowProvisioningDeviceRegistration', '-parallel-testing-enabled', 'NO', 'build-for-testing'], required=True)
    templates = list((derived / 'Build/Products').glob('WorshipCueUI_*.xctestrun'))
    if not templates:
        raise RuntimeError('No test run produced by build-for-testing')
    template = max(templates, key=lambda path: path.stat().st_mtime)
    native = [f'WorshipCueTests/NativeInkTests/{case}' for case in [
        'testM1LegacyMigrationPreservesPDFAndExactExistingInk',
        'testM1VersionPreferenceBookmarkAndImportDoNotAutomaticallyNavigateOrMerge',
        'testM1PacketSlicesKeepArrangerAnnotationsAndRollbackInvalidBatch',
        'testM1FallbackExportMatchesRotationsAndExcludesUnselectedInk']]
    if args.full_native:
        native = ['WorshipCueTests']
    groups = []
    if args.group in ('native', 'all'):
        groups.append(('native', native))
    if args.group in ('ui', 'all'):
        # Keep independent workflow results inspectable when an Apple runner fails to start.
        for label, case in [('workspace', 'testM1WorkspaceSearchPreferenceSetlistStandbyAndColdRelaunch'),
                            ('export-ui', 'testM1ExportLayerChoiceAndShareSheet'),
                            ('packet', 'testM1WeeklyPacketRangesKeepReaderAndCreateIndependentSongs'),
                            ('clone', 'testM1SetlistRepeatAndCloneKeepOriginalOccurrencesAndKeys'),
                            ('v2', 'testV2ConceptLayoutNavigationAndManualVersionInspector'),
                            ('team-setup', 'testTeamSetupKeepsLocalChartPageAndInkAvailable'),
                            ('workspace-sources', 'testBuild8DirectWorkspaceAndLibrarySourcesPreserveReader')]:
            groups.append((label, [f'WorshipCueUITests/MusicStandUITests/{case}']))
        if args.regressions:
            for label, case in [('drawing', 'testDrawingToolsSaveAndColdRelaunch'),
                                ('colors', 'testCompactColorPickerDismissalRenderedColorsAndRememberedChoices'),
                                ('transfer', 'testSelectedTransferCancelCommitUndoAndVersionPageIsolation'),
                                ('team', 'testReadOnlyTeamLayerUsesExactVersionAndPage')]:
                groups.append((label, [f'WorshipCueUITests/MusicStandUITests/{case}']))
    if args.only:
        available = {label for label, _ in groups}
        if not set(args.only) <= available:
            parser.error('Selected groups must be included by --group and --regressions')
        groups = [(label, cases) for label, cases in groups if label in args.only]
    if args.batch_ui:
        ui_cases = [case for label, cases in groups if label != 'native' for case in cases]
        groups = [(label, cases) for label, cases in groups if label == 'native']
        if ui_cases:
            groups.append(('ui-batch', ui_cases))
    failed = False
    for label, cases in groups:
        bundle = output / f'{label}.xcresult'
        code = execute(label, ['xcodebuild', '-xctestrun', str(template), '-destination', f'platform=iOS,id={device}',
            '-destination-timeout', '30', '-parallel-testing-enabled', 'NO', '-collect-test-diagnostics', 'never', '-resultBundlePath', str(bundle),
            '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '180',
            *[f'-only-testing:{case}' for case in cases], 'test-without-building'])
        try:
            summary = json.loads(subprocess.check_output(wrapper + ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(bundle)], cwd=repo, timeout=60))
        except (subprocess.SubprocessError, json.JSONDecodeError):
            results[label]['summaryUnavailable'] = True
            (output / 'results.json').write_text(json.dumps(results, indent=2))
            failed = True
            continue
        results[label]['summary'] = {key: summary.get(key) for key in ['passedTests', 'failedTests', 'skippedTests', 'totalTestCount']}
        expected = len(cases) if all(case.count('/') == 2 for case in cases) else None
        results[label]['expectedTestCount'] = expected
        (output / 'results.json').write_text(json.dumps(results, indent=2))
        print(f'{label}: {results[label]["summary"]}', flush=True)
        if code or not summary.get('passedTests') or summary.get('failedTests', 0) or (expected is not None and summary.get('totalTestCount') != expected):
            failed = True
    if failed:
        raise SystemExit('Some selected checks failed or did not run; inspect their result bundles')
    print('M1_SELECTED_DEVICE_CHECKS_PASSED', flush=True)


if __name__ == '__main__':
    main()
