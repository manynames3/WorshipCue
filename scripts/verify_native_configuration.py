#!/usr/bin/env python3
"""Verify the compiled app's configuration, without printing configuration values."""
import argparse
import json
from pathlib import Path
import plistlib
import sys
from urllib.parse import urlsplit


CUSTOM_KEYS = (
    'WorshipCueRemoteProvider', 'WorshipCueAWSAPIURL', 'WorshipCueAWSWebSocketURL',
    'WorshipCueSupabaseURL', 'WorshipCueSupabaseKey',
)


class VerificationFailed(Exception):
    pass


def check(name, valid):
    print(('PASS ' if valid else 'FAIL ') + name)
    if not valid:
        raise VerificationFailed()


def safe_endpoint(value, scheme):
    try:
        url = urlsplit(value)
        return (url.scheme == scheme and bool(url.hostname) and url.port in (None, 443)
                and url.username is None and url.password is None and not url.query and not url.fragment)
    except ValueError:
        return False


def verify(args):
    built = plistlib.loads((args.app / 'Info.plist').read_bytes())
    check('custom_configuration_keys_present', all(key in built for key in CUSTOM_KEYS))
    check('configuration_build_settings_expanded', all(
        isinstance(built[key], str) and '$(' not in built[key] for key in CUSTOM_KEYS))
    check('configured_provider_selected', built['WorshipCueRemoteProvider'] == args.provider)
    if args.provider == 'aws':
        check('aws_api_endpoint_valid', safe_endpoint(built['WorshipCueAWSAPIURL'], 'https'))
        check('aws_websocket_endpoint_valid', safe_endpoint(built['WorshipCueAWSWebSocketURL'], 'wss'))
        if args.aws_config:
            config = json.loads(args.aws_config.read_text())
            outputs = config.get('outputs', config)
            if isinstance(outputs, list):
                outputs = {row['OutputKey']: row['OutputValue'] for row in outputs}
            check('aws_api_matches_deployed_stack', built['WorshipCueAWSAPIURL'].rstrip('/') ==
                  outputs['APIURL'].rstrip('/'))
            check('aws_websocket_matches_deployed_stack', built['WorshipCueAWSWebSocketURL'].rstrip('/') ==
                  outputs['WebSocketURL'].rstrip('/'))
    else:
        check('supabase_endpoint_and_publishable_key_present',
              safe_endpoint(built['WorshipCueSupabaseURL'], 'https') and bool(built['WorshipCueSupabaseKey']))
    check('standard_bundle_metadata_merged',
          built.get('CFBundlePackageType') == 'APPL' and bool(built.get('CFBundleIdentifier')) and
          bool(built.get('CFBundleShortVersionString')) and bool(built.get('CFBundleVersion')) and
          built.get('MinimumOSVersion') == '16.0' and
          (not args.build_number or built['CFBundleVersion'] == args.build_number))
    check('ipad_presentation_metadata_merged',
          built.get('UIDeviceFamily') == [2] and bool(built.get('UIApplicationSceneManifest')) and
          isinstance(built.get('UILaunchScreen'), dict) and
          set(built.get('UISupportedInterfaceOrientations~ipad', [])) == {
              'UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown',
              'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True, help='Path to the built WorshipCue.app')
    parser.add_argument('--provider', choices=('aws', 'supabase'), default='aws')
    parser.add_argument('--aws-config', type=Path, help='Private deployment output file; values are never printed')
    parser.add_argument('--build-number', help='Expected CFBundleVersion, when qualifying a specific build')
    args = parser.parse_args()
    try:
        verify(args)
    except VerificationFailed:
        return 1
    except (OSError, ValueError, KeyError, TypeError, AttributeError, plistlib.InvalidFileException):
        print('FAIL compiled_bundle_or_deployment_config_unreadable')
        return 1
    print('Compiled app configuration verified')
    return 0


if __name__ == '__main__':
    sys.exit(main())
