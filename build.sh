#!/bin/bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$project_dir"
swift build -c release -Xswiftc -warnings-as-errors
python3 - "$project_dir" <<'PY'
from pathlib import Path
import plistlib, shutil, subprocess, sys
root = Path(sys.argv[1])
for executable, title, identifier in [
    ('Nook', 'Nook', 'com.benzhang.nook'),
    ('NookFixture', 'Nook Fixture', 'com.benzhang.nook.fixture'),
]:
    app = root / 'dist' / (title + '.app')
    macos = app / 'Contents' / 'MacOS'
    macos.mkdir(parents=True, exist_ok=True)
    temporary_executable = macos / (executable + '.new')
    shutil.copy2(root / '.build' / 'release' / executable, temporary_executable)
    temporary_executable.replace(macos / executable)
    resources = app / 'Contents' / 'Resources'
    resources.mkdir(parents=True, exist_ok=True)
    for filename in ['LICENSE', 'NOTICE']:
        shutil.copy2(root / filename, resources / filename)
    info = {'CFBundleExecutable': executable, 'CFBundleIdentifier': identifier,
            'CFBundleName': title, 'CFBundleDisplayName': title, 'CFBundleVersion': '1',
            'CFBundleShortVersionString': '0.1.0', 'CFBundlePackageType': 'APPL',
            'LSUIElement': True, 'LSMinimumSystemVersion': '26.0',
            'NSHumanReadableCopyright': 'Copyright 2026 Ben'}
    (app / 'Contents' / 'Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['xattr', '-cr', str(app)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', '--identifier', identifier, str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
PY
