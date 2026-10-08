#!/usr/bin/env python3
"""Reproducible Xcode project generation using only Python's standard library."""
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'apps/ipad'
objects = {}
ids = {}
def ident(key):
    if key not in ids:
        ids[key] = f'{len(ids)+1:024X}'
    return ids[key]
def obj(key, value):
    objects[ident(key)] = value
    return ident(key)
def quote(value):
    return json.dumps(value, ensure_ascii=False)
def refs(keys):
    return '(' + ', '.join(ident(k) for k in keys) + ',)'

sources = sorted(p.name for p in (APP/'WorshipCue').glob('*.swift'))
for name in sources:
    obj('ref:'+name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(name)}; sourceTree = "<group>";')
    obj('build:'+name, f'isa = PBXBuildFile; fileRef = {ident("ref:"+name)};')
obj('ref:tests', 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NativeInkTests.swift; sourceTree = "<group>";')
obj('build:tests', f'isa = PBXBuildFile; fileRef = {ident("ref:tests")};')
obj('ref:pdfs', 'isa = PBXFileReference; lastKnownFileType = folder; name = pdfs; path = ../../fixtures/pdfs; sourceTree = "<group>";')
obj('ref:notices', 'isa = PBXFileReference; lastKnownFileType = text; path = ThirdPartyNotices.txt; sourceTree = \"<group>\";')
obj('ref:strings', 'isa = PBXFileReference; lastKnownFileType = text.json.xcstrings; path = Localizable.xcstrings; sourceTree = "<group>";')
for key in ['pdfs','strings','notices']:
    obj('build:'+key, f'isa = PBXBuildFile; fileRef = {ident("ref:"+key)};')
obj('product:app', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = WorshipCue.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('product:tests', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = WorshipCueTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
obj('package:local', 'isa = XCLocalSwiftPackageReference; relativePath = ../../packages/WorshipCueLocal;')
obj('package:ink', 'isa = XCLocalSwiftPackageReference; relativePath = ../../packages/WorshipCueInk;')
obj('package:remote', 'isa = XCLocalSwiftPackageReference; relativePath = ../../packages/WorshipCueRemote;')
obj('package:core', 'isa = XCLocalSwiftPackageReference; relativePath = ../../reference/WorshipCueCore;')
for target in ['app','tests']:
    for product, package in [('WorshipCueLocal','local'),('WorshipCueCore','core'),('WorshipCueInk','ink'),('WorshipCueRemote','remote')]:
        key = target+':'+product
        obj(key, f'isa = XCSwiftPackageProductDependency; package = {ident("package:"+package)}; productName = {product};')
        obj('build:'+key, f'isa = PBXBuildFile; productRef = {ident(key)};')
obj('group:app', f'isa = PBXGroup; path = WorshipCue; sourceTree = "<group>"; children = {refs(["ref:"+s for s in sources]+["ref:strings","ref:notices"])};')
obj('group:tests', f'isa = PBXGroup; path = WorshipCueTests; sourceTree = "<group>"; children = {refs(["ref:tests"])};')
obj('group:products', f'isa = PBXGroup; name = Products; sourceTree = "<group>"; children = {refs(["product:app","product:tests"])};')
obj('group:root', f'isa = PBXGroup; sourceTree = "<group>"; children = {refs(["group:app","group:tests","ref:pdfs","group:products"])};')
for target in ['app','tests']:
    obj('sources:'+target, f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(["build:"+s for s in sources] if target=="app" else ["build:tests"])}; runOnlyForDeploymentPostprocessing = 0;')
    obj('frameworks:'+target, f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {refs(["build:"+target+":WorshipCueLocal","build:"+target+":WorshipCueCore","build:"+target+":WorshipCueInk","build:"+target+":WorshipCueRemote"])}; runOnlyForDeploymentPostprocessing = 0;')
    resource_refs = refs(['build:pdfs','build:strings','build:notices']) if target == 'app' else '()'
    obj('resources:'+target, f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {resource_refs}; runOnlyForDeploymentPostprocessing = 0;')

base = {'IPHONEOS_DEPLOYMENT_TARGET':'16.0','SDKROOT':'iphoneos','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES'}
app = {'TARGETED_DEVICE_FAMILY':'2','PRODUCT_NAME':'$(TARGET_NAME)','PRODUCT_BUNDLE_IDENTIFIER':'com.worshipcue.spike',
       'GENERATE_INFOPLIST_FILE':'YES','INFOPLIST_KEY_UILaunchScreen_Generation':'YES',
       'INFOPLIST_KEY_UIApplicationSceneManifest_Generation':'YES','INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents':'YES',
       'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad':'UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight',
       'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','SUPPORTS_MACCATALYST':'NO','CODE_SIGN_STYLE':'Automatic',
       'MARKETING_VERSION':'0.0.1','CURRENT_PROJECT_VERSION':'5','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','SWIFT_EMIT_LOC_STRINGS':'YES',
       'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks',
       'INFOPLIST_KEY_WorshipCueSupabaseURL':'$(SUPABASE_URL)',
       'INFOPLIST_KEY_WorshipCueSupabaseKey':'$(SUPABASE_PUBLISHABLE_KEY)'}
tests = {'TARGETED_DEVICE_FAMILY':'2','PRODUCT_NAME':'$(TARGET_NAME)','PRODUCT_BUNDLE_IDENTIFIER':'com.worshipcue.spike.tests',
         'GENERATE_INFOPLIST_FILE':'YES','TEST_HOST':'$(BUILT_PRODUCTS_DIR)/WorshipCue.app/WorshipCue',
         'BUNDLE_LOADER':'$(TEST_HOST)','CODE_SIGN_STYLE':'Automatic',
         'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @loader_path/Frameworks'}
for owner, settings in [('project',base),('app',app),('tests',tests)]:
    for config in ['Debug','Release']:
        extra = {'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if config=='Debug' else '-O'}
        if owner=='project' and config=='Debug':
            extra['ENABLE_TESTABILITY']='YES'
            extra['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='$(inherited) DEBUG'
        values = ' '.join(f'{k} = {quote(v)};' for k,v in (settings|extra).items())
        obj(owner+':'+config, f'isa = XCBuildConfiguration; buildSettings = {{ {values} }}; name = {config};')
    obj('config:'+owner, f'isa = XCConfigurationList; buildConfigurations = {refs([owner+":Debug",owner+":Release"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('proxy', f'isa = PBXContainerItemProxy; containerPortal = {ident("project")}; proxyType = 1; remoteGlobalIDString = {ident("target:app")}; remoteInfo = WorshipCue;')
obj('dependency', f'isa = PBXTargetDependency; target = {ident("target:app")}; targetProxy = {ident("proxy")};')
for target, name in [('app','WorshipCue'),('tests','WorshipCueTests')]:
    deps = refs(['dependency']) if target == 'tests' else '()'
    product_type = 'com.apple.product-type.application' if target=='app' else 'com.apple.product-type.bundle.unit-test'
    obj('target:'+target, f'isa = PBXNativeTarget; buildConfigurationList = {ident("config:"+target)}; buildPhases = {refs(["sources:"+target,"frameworks:"+target,"resources:"+target])}; buildRules = (); dependencies = {deps}; name = {name}; packageProductDependencies = {refs([target+":WorshipCueLocal",target+":WorshipCueCore",target+":WorshipCueInk",target+":WorshipCueRemote"])}; productName = {name}; productReference = {ident("product:"+target)}; productType = {quote(product_type)};')
obj('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1630; }}; buildConfigurationList = {ident("config:project")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = ko; hasScannedForEncodings = 0; knownRegions = (ko, Base,); mainGroup = {ident("group:root")}; packageReferences = {refs(["package:local","package:core","package:ink","package:remote"])}; productRefGroup = {ident("group:products")}; projectDirPath = ""; projectRoot = ""; targets = {refs(["target:app","target:tests"])};')

# Append UI-test objects so existing app/hosted-test object identities stay stable.
obj('ref:uitests', 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MusicStandUITests.swift; sourceTree = "<group>";')
obj('build:uitests', f'isa = PBXBuildFile; fileRef = {ident("ref:uitests")};')
obj('product:uitests', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = WorshipCueUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
obj('group:uitests', f'isa = PBXGroup; path = WorshipCueUITests; sourceTree = "<group>"; children = {refs(["ref:uitests"])};')
objects[ident('group:root')] = objects[ident('group:root')].replace(ident('group:products')+',', ident('group:uitests')+', '+ident('group:products')+',')
objects[ident('group:products')] = objects[ident('group:products')].replace(ident('product:tests')+',', ident('product:tests')+', '+ident('product:uitests')+',')
for phase, isa in [('sources','PBXSourcesBuildPhase'),('frameworks','PBXFrameworksBuildPhase'),('resources','PBXResourcesBuildPhase')]:
    files = refs(['build:uitests']) if phase == 'sources' else '()'
    obj(phase+':uitests', f'isa = {isa}; buildActionMask = 2147483647; files = {files}; runOnlyForDeploymentPostprocessing = 0;')
ui_settings = {'TARGETED_DEVICE_FAMILY':'2','PRODUCT_NAME':'$(TARGET_NAME)',
               'PRODUCT_BUNDLE_IDENTIFIER':'com.worshipcue.spike.uitests','GENERATE_INFOPLIST_FILE':'YES',
               'TEST_TARGET_NAME':'WorshipCue','CODE_SIGN_STYLE':'Automatic',
               'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @loader_path/Frameworks'}
for config in ['Debug','Release']:
    values = ' '.join(f'{k} = {quote(v)};' for k,v in ui_settings.items())
    obj('uitests:'+config, f'isa = XCBuildConfiguration; buildSettings = {{ {values} }}; name = {config};')
obj('config:uitests', f'isa = XCConfigurationList; buildConfigurations = {refs(["uitests:Debug","uitests:Release"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('target:uitests', f'isa = PBXNativeTarget; buildConfigurationList = {ident("config:uitests")}; buildPhases = {refs(["sources:uitests","frameworks:uitests","resources:uitests"])}; buildRules = (); dependencies = {refs(["dependency"])}; name = WorshipCueUITests; productName = WorshipCueUITests; productReference = {ident("product:uitests")}; productType = "com.apple.product-type.bundle.ui-testing";')
objects[ident('project')] = objects[ident('project')].replace(ident('target:tests')+',', ident('target:tests')+', '+ident('target:uitests')+',')
# Append the asset catalog without changing established target/scheme identities.
obj('ref:assets', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";')
obj('build:assets', f'isa = PBXBuildFile; fileRef = {ident("ref:assets")};')
objects[ident('group:app')] = objects[ident('group:app')].replace(ident('ref:strings')+',', ident('ref:assets')+', '+ident('ref:strings')+',')
objects[ident('resources:app')] = objects[ident('resources:app')].replace(ident('build:strings')+',', ident('build:assets')+', '+ident('build:strings')+',')
obj('ref:teamtests', 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = TeamWorkspaceTests.swift; sourceTree = "<group>";')
obj('build:teamtests', f'isa = PBXBuildFile; fileRef = {ident("ref:teamtests")};')
objects[ident('group:tests')] = objects[ident('group:tests')].replace(ident('ref:tests')+',', ident('ref:tests')+', '+ident('ref:teamtests')+',')
objects[ident('sources:tests')] = objects[ident('sources:tests')].replace(ident('build:tests')+',', ident('build:tests')+', '+ident('build:teamtests')+',')
obj('ref:teamconfig', 'isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Configuration/Team.xcconfig; sourceTree = "<group>";')
objects[ident('group:root')] = objects[ident('group:root')].replace(ident('group:app')+',', ident('group:app')+', '+ident('ref:teamconfig')+',')
for config in ['Debug','Release']:
    objects[ident('project:'+config)] = objects[ident('project:'+config)].replace('buildSettings =', f'baseConfigurationReference = {ident("ref:teamconfig")}; buildSettings =')
project = APP/'WorshipCue.xcodeproj'
project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{\narchiveVersion = 1; classes = {}; objectVersion = 56;\nobjects = {\n'+'\n'.join(f'{key} = {{ {value} }};' for key,value in objects.items())+f'\n}};\nrootObject = {ident("project")};\n}}\n')
ref = lambda target, name: f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target:"+target)}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:WorshipCue.xcodeproj"/>'
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1630" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref('app','WorshipCue.app')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref('tests','WorshipCueTests.xctest')}</TestableReference><TestableReference skipped="NO">{ref('uitests','WorshipCueUITests.xctest')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('app','WorshipCue.app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugServiceExtension="internal"><BuildableProductRunnable runnableDebuggingMode="0">{ref('app','WorshipCue.app')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
folder = project/'xcshareddata/xcschemes'
folder.mkdir(parents=True,exist_ok=True)
# Keep ordinary app/hosted testing independent of UI runner provisioning.
(folder/'WorshipCueUI.xcscheme').write_text(scheme)
ui_testable = f'<TestableReference skipped="NO">{ref("uitests","WorshipCueUITests.xctest")}</TestableReference>'
(folder/'WorshipCue.xcscheme').write_text(scheme.replace(ui_testable, ''))
print(f'Generated {len(sources)} app sources, 2 hosted test sources, 1 UI test source, schemes WorshipCue / WorshipCueUI')
