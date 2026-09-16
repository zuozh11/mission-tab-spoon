#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$project_dir" <<'PY'
from pathlib import Path
import datetime, re, shutil, sys
source = Path(sys.argv[1]) / 'MissionTab.spoon'
config = Path.home() / '.hammerspoon'
destination = config / 'Spoons' / 'MissionTab.spoon'
config.mkdir(parents=True, exist_ok=True)
destination.parent.mkdir(parents=True, exist_ok=True)
stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
if destination.exists() or destination.is_symlink():
    destination.rename(destination.with_name(destination.name + '.backup-' + stamp))
shutil.copytree(source, destination)
init = config / 'init.lua'
text = init.read_text() if init.exists() else ''
# Preserve manual configurations, including indirect loaders and commented examples.
# A reference we cannot interpret is safer to leave for the user than to duplicate.
if not re.search(r'\bMissionTab\b', text):
    if init.exists():
        shutil.copy2(init, init.with_name(init.name + '.backup-' + stamp))
    text += "\n-- MissionTab BEGIN\nhs.loadSpoon('MissionTab'):start()\n-- MissionTab END\n"
    init.write_text(text)
else:
    print('Existing MissionTab configuration or reference preserved; ensure it loads and starts the Spoon.')
print('Installed:', destination)
print('Reload Hammerspoon config to enable MissionTab.')
PY
