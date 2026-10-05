#!/usr/bin/env python3
import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile


@dataclass(frozen=True)
class Bundle:
    executable: str
    name: str
    identifier: str


APP = Bundle("Nook", "Nook", "com.benzhang.nook")
FIXTURE = Bundle("NookFixture", "Nook Fixture", "com.benzhang.nook.fixture")
ARCHITECTURES = ("arm64", "x86_64")
VERSION_PATTERN = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"


def read_version(root):
    version = (root / "VERSION").read_text().strip()
    if not re.fullmatch(VERSION_PATTERN, version):
        raise ValueError("VERSION must contain MAJOR.MINOR.PATCH without leading zeros")
    return version


def check_tag(version, tag):
    if tag != "v" + version:
        raise ValueError(f"Release tag {tag!r} does not match VERSION ({version})")


def bundle_info(bundle, version, minimum_macos):
    return {
        "CFBundleExecutable": bundle.executable,
        "CFBundleIdentifier": bundle.identifier,
        "CFBundleName": bundle.name,
        "CFBundleDisplayName": bundle.name,
        "CFBundleVersion": version,
        "CFBundleShortVersionString": version,
        "CFBundlePackageType": "APPL",
        "LSUIElement": True,
        "LSMinimumSystemVersion": minimum_macos,
        "NSHumanReadableCopyright": "Copyright 2026 Ben. GPL-3.0; see LICENSE and NOTICE.",
    }


def verify_bundle(app, version, minimum_macos):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info != bundle_info(APP, version, minimum_macos):
        raise ValueError("The release app metadata does not match its version and platform")
    executable = app / "Contents/MacOS" / APP.executable
    if not executable.stat().st_mode & 0o111:
        raise ValueError("The packaged app executable has lost its executable permissions")
    for name in ("LICENSE", "NOTICE"):
        if not (app / "Contents/Resources" / name).is_file():
            raise ValueError(f"The packaged app is missing {name}")
    subprocess.run(["lipo", str(executable), "-verify_arch", *ARCHITECTURES], check=True)
    subprocess.run(["codesign", "--verify", "--strict", "--all-architectures", str(app)], check=True)


def extract_app_archive(archive, destination):
    with zipfile.ZipFile(archive) as zipped:
        members = zipped.infolist()
        names = [member.filename for member in members]
        if not members or len(names) != len(set(names)):
            raise ValueError("The app archive is empty or contains duplicate paths")
        for member in members:
            path = PurePosixPath(member.filename)
            mode = member.external_attr >> 16
            if path.is_absolute() or ".." in path.parts or path.parts[0] != "Nook.app":
                raise ValueError(f"Unsafe app archive path: {member.filename}")
            if stat.S_ISLNK(mode):
                raise ValueError(f"Unexpected symlink in the app archive: {member.filename}")
        zipped.extractall(destination)
        for member in members:
            if not member.is_dir():
                (destination / member.filename).chmod(stat.S_IMODE(member.external_attr >> 16))
    return destination / "Nook.app"


def verify_app_archive(archive, version, minimum_macos):
    with tempfile.TemporaryDirectory(prefix="nook-archive-") as directory:
        app = extract_app_archive(archive, Path(directory))
        verify_bundle(app, version, minimum_macos)


def build(root, version):
    if sys.platform != "darwin":
        raise RuntimeError("Building Nook requires macOS and Xcode 26 or newer")
    manifest = json.loads(subprocess.check_output(
        ["swift", "package", "dump-package"], cwd=root, text=True
    ))
    platforms = [p for p in manifest["platforms"] if p["platformName"] == "macos"]
    if len(platforms) != 1:
        raise ValueError("Package.swift must specify exactly one macOS deployment target")
    minimum_macos = platforms[0]["version"]
    arguments = ["swift", "build", "-c", "release", "-Xswiftc", "-warnings-as-errors"]
    for architecture in ARCHITECTURES:
        arguments.extend(["--arch", architecture])
    subprocess.run(arguments, cwd=root, check=True)
    binary_directory = Path(subprocess.check_output(
        arguments + ["--show-bin-path"], cwd=root, text=True
    ).strip())
    output = root / "dist"
    output.mkdir(exist_ok=True)
    for bundle in (APP, FIXTURE):
        app = output / (bundle.name + ".app")
        if app.exists():
            shutil.rmtree(app)
        macos = app / "Contents/MacOS"
        resources = app / "Contents/Resources"
        macos.mkdir(parents=True)
        resources.mkdir()
        shutil.copy2(binary_directory / bundle.executable, macos / bundle.executable)
        for name in ("LICENSE", "NOTICE"):
            shutil.copy2(root / name, resources / name)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(
            bundle_info(bundle, version, minimum_macos)
        ))
        subprocess.run(["xattr", "-cr", str(app)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", "--identifier",
                        bundle.identifier, str(app)], check=True)
        subprocess.run(["codesign", "--verify", "--strict", "--all-architectures", str(app)], check=True)
    verify_bundle(output / "Nook.app", version, minimum_macos)
    return minimum_macos


def release(root, version, tag):
    check_tag(version, tag)
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True).strip():
        raise ValueError("Commit all source changes before packaging a release")
    tracked_version = subprocess.check_output(["git", "show", "HEAD:VERSION"], cwd=root, text=True).strip()
    if tracked_version != version:
        raise ValueError("VERSION does not match the source commit being archived")
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    minimum_macos = build(root, version)
    output = root / "dist"
    app = output / "Nook.app"
    archive = output / f"Nook-{version}-macos-universal.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as zipped:
        for file in sorted(app.rglob("*")):
            if file.is_symlink():
                raise ValueError(f"Unexpected symlink in the release app: {file}")
            if file.is_file():
                zipped.write(file, file.relative_to(output))
    verify_app_archive(archive, version, minimum_macos)
    source = output / f"Nook-{version}-source.zip"
    subprocess.run(["git", "archive", "--format=zip", f"--prefix=nook-{version}/",
                    f"--output={source}", commit], cwd=root, check=True)
    with zipfile.ZipFile(source) as zipped:
        if zipped.testzip() is not None:
            raise ValueError("The corresponding source archive is corrupt")
        if zipped.read(f"nook-{version}/VERSION").decode().strip() != version:
            raise ValueError("The source archive version does not match the app")
    checksums = {file.name: hashlib.sha256(file.read_bytes()).hexdigest() for file in (archive, source)}
    (output / "SHA256SUMS.txt").write_text("".join(f"{digest}  {name}\n" for name, digest in checksums.items()))
    (output / "release.json").write_text(json.dumps({
        "version": version, "tag": tag, "commit": commit,
        "minimumMacOS": minimum_macos, "architectures": ARCHITECTURES,
        "signing": "ad-hoc", "notarized": False, "checksums": checksums,
    }, indent=2) + "\n")
    (output / "release-notes.md").write_text(
        f"Experimental Nook prerelease for macOS {minimum_macos} or newer. "
        "The app contains both Apple Silicon and Intel code.\n\n"
        "Hide menu-bar icons, reveal one when needed, and let it hide after its native interface closes. "
        "Control–Option–M opens the selector.\n\n"
        "**Known limits:** native icon ordering and layout settlement can fail, including movement of icons "
        "clipped by a display notch. External displays and multi-day stability are not validated.\n\n"
        "**Signing:** ad-hoc signed, without Developer ID signing or Apple notarization. "
        "See the [installation instructions](https://github.com/ben-z/nook#install).\n\n"
        f"Source commit: `{commit}`. Corresponding source, GPL-3.0 license and Ice attribution are included "
        "in the source ZIP; LICENSE and NOTICE are also bundled in the app.\n"
    )
    print(f"Verified release artifacts: {archive.name}, {source.name}")


def main():
    parser = argparse.ArgumentParser(description="Build and package Nook")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("build")
    package = commands.add_parser("release")
    package.add_argument("--tag", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    version = read_version(root)
    if args.command == "build":
        build(root, version)
    else:
        release(root, version, args.tag)


if __name__ == "__main__":
    main()
