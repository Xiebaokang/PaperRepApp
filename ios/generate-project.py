#!/usr/bin/env python3
"""Generate the dependency-free Xcode project after adding/removing Swift files."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parent
project = root / 'PaperRep.xcodeproj'
project.mkdir(exist_ok=True)
objects = []
def uid(key): return hashlib.sha1(key.encode()).hexdigest()[:24].upper()
def add(key, value): objects.append(f'{uid(key)} = {{ {value} }};'); return uid(key)
def array(items): return '(' + ', '.join(items) + ',)' if items else '()'
def quote(value): return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'

targets = [('PaperRepIOS', 'PaperRep', 'PaperRep', 'com.apple.product-type.application'), ('PaperRepTests', 'PaperRepTests', 'PaperRepTests', 'com.apple.product-type.bundle.unit-test'), ('PaperRepUITests', 'PaperRepUITests', 'PaperRepUITests', 'com.apple.product-type.bundle.ui-testing')]
products = []
groups = []
for target, directory, product, product_type in targets:
    refs = []; build_files = []
    for file in sorted((root / directory).glob('*.swift')):
        key = directory + '/' + file.name
        refs.append(add(key, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(file.name)}; sourceTree = "<group>";'))
        build_files.append(add(key + ':build', f'isa = PBXBuildFile; fileRef = {uid(key)};'))
    resources = []
    if target == 'PaperRepIOS':
        asset = add('assets', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";')
        refs.append(asset); resources.append(add('assets:build', f'isa = PBXBuildFile; fileRef = {asset};'))
        refs.append(add('plist', 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";'))
    groups.append(add(target + ':group', f'isa = PBXGroup; children = {array(refs)}; path = {directory}; sourceTree = "<group>";'))
    ext = 'app' if target == 'PaperRepIOS' else 'xctest'
    product_ref = add(target + ':product', f'isa = PBXFileReference; explicitFileType = {"wrapper.application" if ext == "app" else "wrapper.cfbundle"}; includeInIndex = 0; path = {product}.{ext}; sourceTree = BUILT_PRODUCTS_DIR;')
    products.append(product_ref)
    phases = [add(target + ':sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {array(build_files)}; runOnlyForDeploymentPostprocessing = 0;'), add(target + ':resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {array(resources)}; runOnlyForDeploymentPostprocessing = 0;'), add(target + ':frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')]
    configs = []
    for config in ['Debug', 'Release']:
        settings = {'PRODUCT_NAME': product, 'PRODUCT_BUNDLE_IDENTIFIER': 'com.paperrep.ios' + ('.tests' if target == 'PaperRepTests' else '.uitests' if target == 'PaperRepUITests' else ''), 'SWIFT_VERSION': '5.0', 'IPHONEOS_DEPLOYMENT_TARGET': '17.0', 'TARGETED_DEVICE_FAMILY': '1', 'CODE_SIGN_STYLE': 'Automatic', 'GENERATE_INFOPLIST_FILE': 'YES', 'SWIFT_EMIT_LOC_STRINGS': 'YES'}
        if target == 'PaperRepIOS': settings.update({'INFOPLIST_FILE': 'PaperRep/Info.plist', 'PRODUCT_MODULE_NAME': 'PaperRepIOS', 'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon', 'CURRENT_PROJECT_VERSION': '1', 'MARKETING_VERSION': '1.0.0', 'ENABLE_PREVIEWS': 'YES', 'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator', 'SUPPORTS_MACCATALYST': 'NO'})
        if target == 'PaperRepTests': settings.update({'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/PaperRep.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/PaperRep', 'BUNDLE_LOADER': '$(TEST_HOST)'})
        if target == 'PaperRepUITests': settings['TEST_TARGET_NAME'] = 'PaperRepIOS'
        configs.append(add(target + ':' + config, 'isa = XCBuildConfiguration; buildSettings = { ' + ' '.join(f'{k} = {quote(v)};' for k, v in settings.items()) + f' }}; name = {config};'))
    config_list = add(target + ':configs', f'isa = XCConfigurationList; buildConfigurations = {array(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    dependencies = []
    if target != 'PaperRepIOS':
        proxy = add(target + ':proxy', f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("PaperRepIOS:target")}; remoteInfo = PaperRepIOS;')
        dependencies.append(add(target + ':dependency', f'isa = PBXTargetDependency; target = {uid("PaperRepIOS:target")}; targetProxy = {proxy};'))
    add(target + ':target', f'isa = PBXNativeTarget; buildConfigurationList = {config_list}; buildPhases = {array(phases)}; buildRules = (); dependencies = {array(dependencies) if dependencies else "()"}; name = {target}; productName = {product}; productReference = {product_ref}; productType = "{product_type}";')

product_group = add('products', f'isa = PBXGroup; children = {array(products)}; name = Products; sourceTree = "<group>";')
main_group = add('main', f'isa = PBXGroup; children = {array(groups + [product_group])}; sourceTree = "<group>";')
configs = []
for config in ['Debug', 'Release']:
    settings = {'CLANG_ENABLE_MODULES': 'YES', 'SDKROOT': 'iphoneos', 'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if config == 'Debug' else '-O', 'ENABLE_TESTABILITY': 'YES' if config == 'Debug' else 'NO', 'DEBUG_INFORMATION_FORMAT': 'dwarf' if config == 'Debug' else 'dwarf-with-dsym', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG' if config == 'Debug' else '', 'CLANG_ENABLE_OBJC_ARC': 'YES'}
    configs.append(add('project:' + config, 'isa = XCBuildConfiguration; buildSettings = { ' + ' '.join(f'{k} = {quote(v)};' for k, v in settings.items()) + f' }}; name = {config};'))
config_list = add('project:configs', f'isa = XCConfigurationList; buildConfigurations = {array(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
add('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2660; }}; buildConfigurationList = {config_list}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh-Hans; hasScannedForEncodings = 0; knownRegions = ("zh-Hans", en, Base); mainGroup = {main_group}; productRefGroup = {product_group}; projectDirPath = ""; projectRoot = ""; targets = {array([uid(t[0] + ":target") for t in targets])};')
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {uid("project")}; }}\n')
schemes = project / 'xcshareddata/xcschemes'; schemes.mkdir(parents=True, exist_ok=True)
def ref(target, product): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(target + ":target")}" BuildableName="{product}" BlueprintName="{target}" ReferencedContainer="container:PaperRep.xcodeproj"/>'
app_ref = ref('PaperRepIOS', 'PaperRep.app')
(schemes / 'PaperRep.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO"><CommandLineArguments><CommandLineArgument argument="--ui-testing" isEnabled="YES"/></CommandLineArguments><Testables><TestableReference skipped="NO">{ref('PaperRepTests','PaperRepTests.xctest')}</TestableReference><TestableReference skipped="NO">{ref('PaperRepUITests','PaperRepUITests.xctest')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(project)
