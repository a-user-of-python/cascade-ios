#!/usr/bin/env python3
"""Generate CascadePort.xcodeproj (deterministic).

Targets:
  CascadeKit  — static library: the OCCT subset sources shipped
                under OCCT/src + Facade/occt_facade.cpp. All geometry
                comes from the Open CASCADE libraries themselves.
  CascadeDemo — iPad SwiftUI app (com.user.cascadedemo) that links
                CascadeKit and calls the façade through a bridging
                header. Swift drives; Cascade does the geometry.

UUIDs are md5-derived from stable keys, so regenerating produces a
byte-identical project. Run:  python3 gen_project.py
"""
import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
PROJ_DIR = os.path.join(ROOT, "CascadePort.xcodeproj")

_used = set()


def U(key):
    h = hashlib.md5(key.encode()).hexdigest()[:24].upper()
    assert h not in _used, f"uuid collision: {key}"
    _used.add(h)
    return h


def collect():
    src_root = os.path.join(ROOT, "OCCT", "src")
    sources, headers, header_dirs = [], [], set()
    for dirpath, dirnames, filenames in os.walk(src_root):
        dirnames.sort()
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, ROOT)
            ext = fn.rsplit(".", 1)[-1]
            if ext in ("cxx", "c", "cpp"):
                sources.append(rel)
            elif ext in ("hxx", "lxx", "pxx", "gxx", "h"):
                headers.append(rel)
                header_dirs.add(os.path.relpath(dirpath, ROOT))
    headers.append("OCCT/generated/Standard_Version.hxx")
    header_dirs.add("OCCT/generated")
    header_dirs.add("Facade")
    return sorted(sources), sorted(headers), sorted(header_dirs)


OCCT_SOURCES, OCCT_HEADERS, HEADER_DIRS = collect()
FACADE_SRC = "Facade/occt_facade.cpp"
FACADE_HDR = "Facade/occt_facade.h"
DEMO_SOURCES = [
    "DemoApp/CascadeDemoApp.swift",
    "DemoApp/CascadeEngine.swift",
    "DemoApp/ContentView.swift",
]
DEMO_OTHER_FILES = [
    "DemoApp/CascadeDemo-Bridging-Header.h",
    "DemoApp/Info.plist",
    "DemoApp/Assets.xcassets",
]

FILETYPE = {
    "cxx": "sourcecode.cpp.cpp",
    "cpp": "sourcecode.cpp.cpp",
    "c": "sourcecode.c.c",
    "hxx": "sourcecode.cpp.h",
    "h": "sourcecode.c.h",
    "lxx": "sourcecode.cpp.h",
    "pxx": "sourcecode.cpp.h",
    "gxx": "sourcecode.cpp.h",
    "swift": "sourcecode.swift",
    "plist": "text.plist.xml",
    "xcassets": "folder.assetcatalog",
}

fileref_id = {}   # path -> PBXFileReference id
buildfile_id = {}  # (path, phase) -> PBXBuildFile id


def fileref(path):
    if path not in fileref_id:
        fileref_id[path] = U("fileref:" + path)
    return fileref_id[path]


def buildfile(path, phase, attributes=None):
    key = (path, phase)
    if key not in buildfile_id:
        buildfile_id[key] = U(f"buildfile:{phase}:{path}")
    return buildfile_id[key]


# Pre-register every file reference.
ALL_PATHS = (OCCT_SOURCES + OCCT_HEADERS + [FACADE_SRC, FACADE_HDR]
             + DEMO_SOURCES + DEMO_OTHER_FILES)
for p in ALL_PATHS:
    fileref(p)
LIB_REF = U("product:libCascadeKit.a")
APP_REF = U("product:CascadeDemo.app")
for p in OCCT_SOURCES + [FACADE_SRC]:
    buildfile(p, "kit-sources")
for p in OCCT_HEADERS + [FACADE_HDR]:
    buildfile(p, "kit-headers")
for p in DEMO_SOURCES:
    buildfile(p, "app-sources")
buildfile("DemoApp/Assets.xcassets", "app-resources")
LIB_BUILDFILE_APP = U("buildfile:app-frameworks:libCascadeKit.a")

KIT_TARGET = U("target:CascadeKit")
APP_TARGET = U("target:CascadeDemo")
KIT_SOURCES_PHASE = U("phase:kit-sources")
KIT_HEADERS_PHASE = U("phase:kit-headers")
KIT_FRAMEWORKS_PHASE = U("phase:kit-frameworks")
APP_SOURCES_PHASE = U("phase:app-sources")
APP_FRAMEWORKS_PHASE = U("phase:app-frameworks")
APP_RESOURCES_PHASE = U("phase:app-resources")
PROXY = U("proxy:CascadeKit")
APP_DEP = U("dep:app->kit")
PROJECT = U("project:CascadePort")
MAIN_GROUP = U("group:main")
KIT_GROUP = U("group:CascadeKit")
OCCT_GROUP = U("group:OCCT")
FACADE_GROUP = U("group:Facade")
APP_GROUP = U("group:DemoApp")
PRODUCTS_GROUP = U("group:Products")
PROJ_CFG_LIST = U("cfglist:project")
KIT_CFG_LIST = U("cfglist:kit")
APP_CFG_LIST = U("cfglist:app")
PROJ_DEBUG = U("cfg:project:Debug")
PROJ_RELEASE = U("cfg:project:Release")
KIT_DEBUG = U("cfg:kit:Debug")
KIT_RELEASE = U("cfg:kit:Release")
APP_DEBUG = U("cfg:app:Debug")
APP_RELEASE = U("cfg:app:Release")

out = []


def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def q(s):
    if s and all(c.isalnum() or c in "_./$()+-" for c in s):
        return s
    return '"' + esc(s) + '"'


def fileref_line(path):
    ext = path.rsplit(".", 1)[-1]
    ftype = FILETYPE[ext]
    name = os.path.basename(path)
    return (f"\t\t{fileref(path)} /* {name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = {ftype}; name = {q(name)}; "
            f"path = {q(path)}; sourceTree = SOURCE_ROOT; }};")


def buildfile_line(path, phase, attributes=None):
    name = os.path.basename(path)
    attrs = ""
    if attributes:
        attrs = f"; settings = {{ATTRIBUTES = ({', '.join(attributes)}); }}"
    return (f"\t\t{buildfile(path, phase)} /* {name} in {phase} */ = "
            f"{{isa = PBXBuildFile; fileRef = {fileref(path)} /* {name} */{attrs}; }};")


def settings_block(d, indent="\t\t\t\t"):
    lines = []
    for k in sorted(d):
        v = d[k]
        if isinstance(v, list):
            lines.append(f"{indent}{k} = (")
            for item in v:
                lines.append(f"{indent}\t{q(item)},")
            lines.append(f"{indent});")
        else:
            lines.append(f"{indent}{k} = {q(v)};")
    return lines


def config(cid, name, settings):
    lines = [f"\t\t{cid} /* {name} */ = {{",
             "\t\t\tisa = XCBuildConfiguration;",
             "\t\t\tbuildSettings = {"]
    lines += settings_block(settings)
    lines += ["\t\t\t};", f"\t\t\tname = {name};", "\t\t};"]
    return lines


def main():
    search_paths = ["$(inherited)"] + [f"$(SRCROOT)/{d}" for d in HEADER_DIRS]

    proj_common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_CXX_LANGUAGE_STANDARD": "gnu++17",
        "CLANG_ENABLE_MODULES": "YES",
        "GCC_ENABLE_CPP_EXCEPTIONS": "YES",
        "GCC_ENABLE_CPP_RTTI": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "SDKROOT": "iphoneos",
        "TARGETED_DEVICE_FAMILY": "2",
    }
    kit_settings = {
        "ARCHS": "arm64",
        "DEFINES_MODULE": "NO",
        "GCC_PREPROCESSOR_DEFINITIONS": [
            "$(inherited)", "OCC_CONVERT_SIGNALS", "No_Exception",
            "OCCT_NO_PLUGINS", "NDEBUG",
        ],
        "HEADER_SEARCH_PATHS": search_paths,
        "PRODUCT_NAME": "CascadeKit",
        "SKIP_INSTALL": "YES",
    }
    app_settings = {
        "ARCHS": "arm64",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": "",
        "GENERATE_INFOPLIST_FILE": "NO",
        "HEADER_SEARCH_PATHS": ["$(inherited)", "$(SRCROOT)/Facade"],
        "INFOPLIST_FILE": "DemoApp/Info.plist",
        "MARKETING_VERSION": "1.0",
        "OTHER_LDFLAGS": "-lc++",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.user.cascadedemo",
        "PRODUCT_NAME": "CascadeDemo",
        "SWIFT_OBJC_BRIDGING_HEADER": "DemoApp/CascadeDemo-Bridging-Header.h",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": "2",
    }

    o = out.append
    o("// !$*UTF8*$!")
    o("{")
    o("\tarchiveVersion = 1;")
    o("\tclasses = {")
    o("\t};")
    o("\tobjectVersion = 56;")
    o("\tobjects = {")
    o("")

    # PBXBuildFile
    o("/* Begin PBXBuildFile section */")
    for p in OCCT_SOURCES + [FACADE_SRC]:
        o(buildfile_line(p, "kit-sources"))
    for p in OCCT_HEADERS + [FACADE_HDR]:
        o(buildfile_line(p, "kit-headers", attributes=["Project"]))
    for p in DEMO_SOURCES:
        o(buildfile_line(p, "app-sources"))
    o(buildfile_line("DemoApp/Assets.xcassets", "app-resources"))
    o(f"\t\t{LIB_BUILDFILE_APP} /* libCascadeKit.a in Frameworks */ = "
      f"{{isa = PBXBuildFile; fileRef = {LIB_REF} /* libCascadeKit.a */; }};")
    o("/* End PBXBuildFile section */")
    o("")

    # PBXContainerItemProxy
    o("/* Begin PBXContainerItemProxy section */")
    o(f"\t\t{PROXY} /* PBXContainerItemProxy */ = {{")
    o("\t\t\tisa = PBXContainerItemProxy;")
    o(f"\t\t\tcontainerPortal = {PROJECT} /* Project object */;")
    o("\t\t\tproxyType = 1;")
    o(f"\t\t\tremoteGlobalIDString = {KIT_TARGET};")
    o("\t\t\tremoteInfo = CascadeKit;")
    o("\t\t};")
    o("/* End PBXContainerItemProxy section */")
    o("")

    # PBXFileReference
    o("/* Begin PBXFileReference section */")
    for p in ALL_PATHS:
        o(fileref_line(p))
    o(f"\t\t{LIB_REF} /* libCascadeKit.a */ = {{isa = PBXFileReference; "
      "explicitFileType = archive.ar; includeInIndex = 0; "
      "path = libCascadeKit.a; sourceTree = BUILT_PRODUCTS_DIR; };")
    o(f"\t\t{APP_REF} /* CascadeDemo.app */ = {{isa = PBXFileReference; "
      "explicitFileType = wrapper.application; includeInIndex = 0; "
      "path = CascadeDemo.app; sourceTree = BUILT_PRODUCTS_DIR; };")
    o("/* End PBXFileReference section */")
    o("")

    # Build phases
    o("/* Begin PBXFrameworksBuildPhase section */")
    for pid, name, files in [
            (KIT_FRAMEWORKS_PHASE, "kit-frameworks", []),
            (APP_FRAMEWORKS_PHASE, "app-frameworks", [LIB_BUILDFILE_APP])]:
        o(f"\t\t{pid} /* Frameworks */ = {{")
        o("\t\t\tisa = PBXFrameworksBuildPhase;")
        o("\t\t\tbuildActionMask = 2147483647;")
        o("\t\t\tfiles = (")
        for f in files:
            o(f"\t\t\t\t{f} /* libCascadeKit.a in Frameworks */,")
        o("\t\t\t);")
        o("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        o("\t\t};")
    o("/* End PBXFrameworksBuildPhase section */")
    o("")

    o("/* Begin PBXHeadersBuildPhase section */")
    o(f"\t\t{KIT_HEADERS_PHASE} /* Headers */ = {{")
    o("\t\t\tisa = PBXHeadersBuildPhase;")
    o("\t\t\tbuildActionMask = 2147483647;")
    o("\t\t\tfiles = (")
    for p in OCCT_HEADERS + [FACADE_HDR]:
        o(f"\t\t\t\t{buildfile(p, 'kit-headers')} /* {os.path.basename(p)} in kit-headers */,")
    o("\t\t\t);")
    o("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    o("\t\t};")
    o("/* End PBXHeadersBuildPhase section */")
    o("")

    o("/* Begin PBXResourcesBuildPhase section */")
    o(f"\t\t{APP_RESOURCES_PHASE} /* Resources */ = {{")
    o("\t\t\tisa = PBXResourcesBuildPhase;")
    o("\t\t\tbuildActionMask = 2147483647;")
    o("\t\t\tfiles = (")
    o(f"\t\t\t\t{buildfile('DemoApp/Assets.xcassets', 'app-resources')} /* Assets.xcassets in Resources */,")
    o("\t\t\t);")
    o("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    o("\t\t};")
    o("/* End PBXResourcesBuildPhase section */")
    o("")

    o("/* Begin PBXSourcesBuildPhase section */")
    for pid, phase, paths in [
            (KIT_SOURCES_PHASE, "kit-sources", OCCT_SOURCES + [FACADE_SRC]),
            (APP_SOURCES_PHASE, "app-sources", DEMO_SOURCES)]:
        o(f"\t\t{pid} /* Sources */ = {{")
        o("\t\t\tisa = PBXSourcesBuildPhase;")
        o("\t\t\tbuildActionMask = 2147483647;")
        o("\t\t\tfiles = (")
        for p in paths:
            o(f"\t\t\t\t{buildfile(p, phase)} /* {os.path.basename(p)} in Sources */,")
        o("\t\t\t);")
        o("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        o("\t\t};")
    o("/* End PBXSourcesBuildPhase section */")
    o("")

    # Groups
    o("/* Begin PBXGroup section */")

    def group(gid, name, children, path=None):
        o(f"\t\t{gid} /* {name} */ = {{")
        o("\t\t\tisa = PBXGroup;")
        o("\t\t\tchildren = (")
        for cid, cname in children:
            o(f"\t\t\t\t{cid} /* {cname} */,")
        o("\t\t\t);")
        if path:
            o(f"\t\t\tpath = {q(path)};")
        o(f"\t\t\tname = {q(name)};" if not path else "\t\t\tsourceTree = \"<group>\";")
        if not path:
            o("\t\t\tsourceTree = \"<group>\";")
        o("\t\t};")

    group(OCCT_GROUP, "OCCT",
          [(fileref(p), os.path.basename(p))
           for p in OCCT_SOURCES + OCCT_HEADERS])
    group(FACADE_GROUP, "Facade",
          [(fileref(FACADE_HDR), "occt_facade.h"),
           (fileref(FACADE_SRC), "occt_facade.cpp")])
    group(KIT_GROUP, "CascadeKit",
          [(OCCT_GROUP, "OCCT"), (FACADE_GROUP, "Facade")])
    group(APP_GROUP, "DemoApp",
          [(fileref(p), os.path.basename(p)) for p in DEMO_SOURCES + DEMO_OTHER_FILES])
    group(PRODUCTS_GROUP, "Products",
          [(LIB_REF, "libCascadeKit.a"), (APP_REF, "CascadeDemo.app")])
    group(MAIN_GROUP, "Main",
          [(KIT_GROUP, "CascadeKit"), (APP_GROUP, "DemoApp"),
           (PRODUCTS_GROUP, "Products")])
    o("/* End PBXGroup section */")
    o("")

    # Targets
    o("/* Begin PBXNativeTarget section */")
    o(f"\t\t{KIT_TARGET} /* CascadeKit */ = {{")
    o("\t\t\tisa = PBXNativeTarget;")
    o(f"\t\t\tbuildConfigurationList = {KIT_CFG_LIST} /* Build configuration list for PBXNativeTarget \"CascadeKit\" */;")
    o("\t\t\tbuildPhases = (")
    o(f"\t\t\t\t{KIT_HEADERS_PHASE} /* Headers */,")
    o(f"\t\t\t\t{KIT_SOURCES_PHASE} /* Sources */,")
    o(f"\t\t\t\t{KIT_FRAMEWORKS_PHASE} /* Frameworks */,")
    o("\t\t\t);")
    o("\t\t\tbuildRules = ();")
    o("\t\t\tdependencies = ();")
    o("\t\t\tname = CascadeKit;")
    o(f"\t\t\tproductName = CascadeKit;")
    o(f"\t\t\tproductReference = {LIB_REF} /* libCascadeKit.a */;")
    o("\t\t\tproductType = \"com.apple.product-type.library.static\";")
    o("\t\t};")
    o(f"\t\t{APP_TARGET} /* CascadeDemo */ = {{")
    o("\t\t\tisa = PBXNativeTarget;")
    o(f"\t\t\tbuildConfigurationList = {APP_CFG_LIST} /* Build configuration list for PBXNativeTarget \"CascadeDemo\" */;")
    o("\t\t\tbuildPhases = (")
    o(f"\t\t\t\t{APP_SOURCES_PHASE} /* Sources */,")
    o(f"\t\t\t\t{APP_FRAMEWORKS_PHASE} /* Frameworks */,")
    o(f"\t\t\t\t{APP_RESOURCES_PHASE} /* Resources */,")
    o("\t\t\t);")
    o("\t\t\tbuildRules = ();")
    o("\t\t\tdependencies = (")
    o(f"\t\t\t\t{APP_DEP} /* PBXTargetDependency */,")
    o("\t\t\t);")
    o("\t\t\tname = CascadeDemo;")
    o(f"\t\t\tproductName = CascadeDemo;")
    o(f"\t\t\tproductReference = {APP_REF} /* CascadeDemo.app */;")
    o("\t\t\tproductType = \"com.apple.product-type.application\";")
    o("\t\t};")
    o("/* End PBXNativeTarget section */")
    o("")

    # Project
    o("/* Begin PBXProject section */")
    o(f"\t\t{PROJECT} /* Project object */ = {{")
    o("\t\t\tisa = PBXProject;")
    o("\t\t\tattributes = {")
    o("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    o("\t\t\t\tLastUpgradeCheck = 1500;")
    o("\t\t\t\tTargetAttributes = {")
    o(f"\t\t\t\t\t{KIT_TARGET} = {{")
    o("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
    o("\t\t\t\t\t};")
    o(f"\t\t\t\t\t{APP_TARGET} = {{")
    o("\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;")
    o("\t\t\t\t\t};")
    o("\t\t\t\t};")
    o("\t\t\t};")
    o(f"\t\t\tbuildConfigurationList = {PROJ_CFG_LIST} /* Build configuration list for PBXProject \"CascadePort\" */;")
    o("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    o("\t\t\tdevelopmentRegion = en;")
    o("\t\t\thasScannedForEncodings = 0;")
    o("\t\t\tknownRegions = (")
    o("\t\t\t\ten,")
    o("\t\t\t\tBase,")
    o("\t\t\t);")
    o(f"\t\t\tmainGroup = {MAIN_GROUP};")
    o(f"\t\t\tproductRefGroup = {PRODUCTS_GROUP} /* Products */;")
    o("\t\t\tprojectDirPath = \"\";")
    o("\t\t\tprojectRoot = \"\";")
    o("\t\t\ttargets = (")
    o(f"\t\t\t\t{KIT_TARGET} /* CascadeKit */,")
    o(f"\t\t\t\t{APP_TARGET} /* CascadeDemo */,")
    o("\t\t\t);")
    o("\t\t};")
    o("/* End PBXProject section */")
    o("")

    # Target dependency
    o("/* Begin PBXTargetDependency section */")
    o(f"\t\t{APP_DEP} /* PBXTargetDependency */ = {{")
    o("\t\t\tisa = PBXTargetDependency;")
    o(f"\t\t\ttarget = {KIT_TARGET} /* CascadeKit */;")
    o(f"\t\t\ttargetProxy = {PROXY} /* PBXContainerItemProxy */;")
    o("\t\t};")
    o("/* End PBXTargetDependency section */")
    o("")

    # Configurations
    o("/* Begin XCBuildConfiguration section */")
    for cid, name, st in [(PROJ_DEBUG, "Debug", proj_common),
                          (PROJ_RELEASE, "Release", proj_common)]:
        for line in config(cid, name, st):
            o(line)
    for cid, name, st in [(KIT_DEBUG, "Debug", kit_settings),
                          (KIT_RELEASE, "Release", kit_settings)]:
        for line in config(cid, name, st):
            o(line)
    for cid, name, st in [(APP_DEBUG, "Debug", app_settings),
                          (APP_RELEASE, "Release", app_settings)]:
        for line in config(cid, name, st):
            o(line)
    o("/* End XCBuildConfiguration section */")
    o("")

    o("/* Begin XCConfigurationList section */")
    for cid, what, ids in [
            (PROJ_CFG_LIST, 'PBXProject "CascadePort"', (PROJ_DEBUG, PROJ_RELEASE)),
            (KIT_CFG_LIST, 'PBXNativeTarget "CascadeKit"', (KIT_DEBUG, KIT_RELEASE)),
            (APP_CFG_LIST, 'PBXNativeTarget "CascadeDemo"', (APP_DEBUG, APP_RELEASE))]:
        o(f"\t\t{cid} /* Build configuration list for {what} */ = {{")
        o("\t\t\tisa = XCConfigurationList;")
        o("\t\t\tbuildConfigurations = (")
        for i, n in zip(ids, ("Debug", "Release")):
            o(f"\t\t\t\t{i} /* {n} */,")
        o("\t\t\t);")
        o("\t\t\tdefaultConfigurationIsVisible = 0;")
        o("\t\t\tdefaultConfigurationName = Release;")
        o("\t\t};")
    o("/* End XCConfigurationList section */")
    o("\t};")
    o(f"\trootObject = {PROJECT} /* Project object */;")
    o("}")

    os.makedirs(PROJ_DIR, exist_ok=True)
    with open(os.path.join(PROJ_DIR, "project.pbxproj"), "w") as f:
        f.write("\n".join(out) + "\n")
    print(f"sources={len(OCCT_SOURCES)} headers={len(OCCT_HEADERS)} "
          f"header_dirs={len(HEADER_DIRS)} lines={len(out)}")


if __name__ == "__main__":
    main()
