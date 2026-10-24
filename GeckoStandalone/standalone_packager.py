#!/usr/bin/env python3
"""Package an independently installable iOS 15 Gecko/TrollStore app.

Upstream Reynard remains credited under GPL-3.0; this project adds a
standalone navigation recovery hook. No credentials or user data are read.
"""
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import zipfile

root = Path.cwd()
work = root / "work-gecko"
out = root / "dist-gecko"
bundle_id = "com.localfix.chatgptgecko.unique.v2"
app_name = "ChatGPTGecko"
source_icon = Path("/tmp/chatgpt-icon-base.png")
hook = Path("/tmp/ChatGPTStandaloneHook.dylib")

def run(*args):
    print("+", " ".join(str(x) for x in args), flush=True)
    subprocess.run([str(x) for x in args], check=True)

def load(p):
    with p.open("rb") as f:
        return plistlib.load(f)

def save(p, d):
    with p.open("wb") as f:
        plistlib.dump(d, f, sort_keys=False)

def get_entitlements(path):
    result = subprocess.run(["ldid", "-e", str(path)], capture_output=True)
    data = result.stdout
    position = data.find(b"<?xml")
    if position < 0:
        position = data.find(b"<plist")
    try:
        return plistlib.loads(data[position:]) if position >= 0 else {}
    except Exception:
        return {}

def sign(executable, entitlements):
    if entitlements:
        f = work / "current-entitlements.plist"
        save(f, entitlements)
        run("ldid", "-S" + str(f), executable)
    else:
        run("ldid", "-S", executable)

def build(base_archive):
    if work.exists():
        shutil.rmtree(work)
    if out.exists():
        shutil.rmtree(out)
    work.mkdir(parents=True)
    out.mkdir(parents=True)
    with zipfile.ZipFile(base_archive) as z:
        assert z.testzip() is None
        z.extractall(work)
    matches = list((work / "Payload").glob("*.app"))
    assert len(matches) == 1, "Expected exactly one source application"
    app = matches[0]
    info = load(app / "Info.plist")
    assert info["CFBundleIdentifier"] == "com.minh-ton.Reynard"
    old_exe = app / info["CFBundleExecutable"]
    app_ent = get_entitlements(old_exe)
    new_app = app.parent / (app_name + ".app")
    app.rename(new_app)
    app = new_app
    extension_details = []
    for ext in sorted((app / "PlugIns").glob("*.appex")):
        ei = load(ext / "Info.plist")
        extension_details.append((ext, ei, ext / ei["CFBundleExecutable"],
                                  get_entitlements(ext / ei["CFBundleExecutable"])))
    old_exe = app / old_exe.name
    new_exe = app / app_name
    old_exe.rename(new_exe)
    info.update({
        "CFBundleIdentifier": bundle_id,
        "CFBundleName": app_name,
        "CFBundleDisplayName": "ChatGPT Gecko",
        "CFBundleExecutable": app_name,
        "CFBundleShortVersionString": "0.3.9",
        "CFBundleVersion": "12",
        "CFBundleIconFile": "ChatGPTIcon",
        "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["ChatGPTIcon"]}},
        "CFBundleIcons~ipad": {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["ChatGPTIconPad"]}},
        "CFBundleURLTypes": [{"CFBundleURLName": bundle_id,
                              "CFBundleURLSchemes": ["chatgptgecko"]}],
    })
    save(app / "Info.plist", info)
    for ext, ei, executable, ent in extension_details:
        suffix = ".Helper" if "Helper" in ext.stem else ".OpenIn"
        ei["CFBundleIdentifier"] = bundle_id + suffix
        ei["CFBundleDisplayName"] = "ChatGPT Gecko" + suffix
        save(ext / "Info.plist", ei)
        if "application-identifier" in ent:
            ent["application-identifier"] = bundle_id + suffix
        sign(executable, ent)
    assert source_icon.is_file() and hook.is_file()
    for filename, px in [
        ("ChatGPTIcon.png", 60), ("ChatGPTIcon@2x.png", 120),
        ("ChatGPTIcon@3x.png", 180), ("ChatGPTIconPad.png", 76),
        ("ChatGPTIconPad@2x.png", 152)
    ]:
        run("magick", source_icon, "-resize", f"{px}x{px}!", app / filename)
    for icon in app.glob("AppIcon*.png"):
        probe = subprocess.check_output(["sips", "-g", "pixelWidth", str(icon)], text=True)
        size = re.search(r"pixelWidth:\s*(\d+)", probe)
        if size:
            run("magick", source_icon, "-resize", f"{size.group(1)}x{size.group(1)}!", icon)
    shutil.copyfile(hook, app / hook.name)
    run("insert_dylib", "--inplace", "--all-yes", "--strip-codesig",
        "@executable_path/ChatGPTStandaloneHook.dylib", new_exe)
    if "application-identifier" in app_ent:
        app_ent["application-identifier"] = bundle_id
    sign(app / hook.name, {})
    sign(new_exe, app_ent)
    license_file = Path("/tmp/REYNARD_LICENSE_GPL3.txt")
    if license_file.is_file():
        shutil.copy2(license_file, app / "LICENSE-GPL-3.0.txt")
    (app / "GeckoSourceAttribution.txt").write_text(
        "Reynard Gecko runtime: https://github.com/minh-ton/reynard-browser (GPL-3.0)\n"
        "Standalone modifications: https://github.com/yuqiuf-create/ChatGPTGeckoBuild\n"
        "Unofficial, not developed or endorsed by OpenAI.\n", encoding="utf8")
    dest = out / "ChatGPTGecko-v0.3.9-NavigationRecovery-iOS15.tipa"
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for file in (work / "Payload").rglob("*"):
            if file.is_file():
                z.write(file, file.relative_to(work))
    with zipfile.ZipFile(dest) as z:
        assert z.testzip() is None
        members = z.namelist()
        assert f"Payload/{app_name}.app/{app_name}" in members
        assert f"Payload/{app_name}.app/ChatGPTStandaloneHook.dylib" in members
    assert load(app / "Info.plist")["CFBundleIdentifier"] == bundle_id
    print("COMPLETED:", dest, dest.stat().st_size, flush=True)

if __name__ == "__main__":
    build(Path(sys.argv[1]))
