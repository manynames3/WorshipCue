#!/usr/bin/env python3
"""Static Xcode structure check. This never substitutes for an SDK build."""
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
app = root / 'apps/ipad'
project = app / 'WorshipCue.xcodeproj'
parsed = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project/'project.pbxproj')]))
objects = parsed['objects']
test_paths = {p.name: p.parent for folder in ['WorshipCueTests', 'WorshipCueUITests'] for p in (app/folder).glob('*.swift')}
for name, folder in [('WorshipCue','WorshipCue'), ('WorshipCueTests','WorshipCueTests'), ('WorshipCueUITests','WorshipCueUITests')]:
    target = next(v for v in objects.values() if v.get('isa') == 'PBXNativeTarget' and v['name']==name)
    phase = next(objects[key] for key in target['buildPhases'] if objects[key]['isa']=='PBXSourcesBuildPhase')
    files = [objects[objects[key]['fileRef']]['path'] for key in phase['files']]
    actual = sorted(p.name for p in (app/folder).glob('*.swift'))
    assert sorted(files)==actual, (name,files,actual)
    print(f'PASS {name}: {len(files)} Swift sources included')
for value in objects.values():
    if value.get('isa') == 'XCLocalSwiftPackageReference':
        assert (app/value['relativePath']/'Package.swift').is_file()
    if value.get('isa') == 'PBXFileReference' and value.get('sourceTree') != 'BUILT_PRODUCTS_DIR':
        path = value['path']
        parent = test_paths.get(path, app/'WorshipCue')
        if path.startswith('../../') or path.startswith('Configuration/'): parent=app
        assert (parent/path).exists(), path
for name, expected_tests in [('WorshipCue',1),('WorshipCueUI',2)]:
    scheme=ET.parse(project/f'xcshareddata/xcschemes/{name}.xcscheme')
    for ref in scheme.findall('.//BuildableReference'):
        target=objects[ref.attrib['BlueprintIdentifier']]
        assert target['name']==ref.attrib['BlueprintName']
        assert objects[target['productReference']]['path']==ref.attrib['BuildableName']
    assert len(scheme.findall('.//TestableReference')) == expected_tests
    assert all(ref.attrib['skipped']=='NO' for ref in scheme.findall('.//TestableReference'))
json.loads((app/'WorshipCue/Localizable.xcstrings').read_text())
print('PASS package/resource references, shared scheme/test IDs, Korean String Catalog JSON')
print('NOT VERIFIED: Xcode SDK compilation, simulator execution, device behavior')
