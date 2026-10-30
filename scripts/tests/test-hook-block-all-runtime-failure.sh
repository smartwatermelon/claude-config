#!/usr/bin/env bash
# Characterize the real dispatcher with synthetic children, never real effects.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "${repo_root}" <<'PY'
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
source = (root / 'scripts/hook-block-all.sh').read_text()
names = re.search(r'REQUIRED_HOOKS=\((.*?)\n\)', source, re.S).group(1).split()
assert len(names) == 11, names
with tempfile.TemporaryDirectory() as temp:
    directory = Path(temp)
    dispatcher = directory / 'hook-block-all.sh'
    dispatcher.write_text(source)
    for code in (0, 1, 2, 42, 127):
        for index, name in enumerate(names):
            path = directory / name
            # Every child consumes input; only the selected one fails.
            path.write_text('#!/usr/bin/env bash\ncat >/dev/null\n'
                            + f'echo {index} >>"{directory}/called"\n'
                            + f'exit {code if index == 2 else 0}\n')
            path.chmod(0o700)
        called = directory / 'called'
        called.unlink(missing_ok=True)
        result = subprocess.run(['bash', str(dispatcher)],
                                input=json.dumps({'tool_input': {
                                    'command': 'synthetic-command'}}),
                                text=True, capture_output=True)
        assert result.returncode == (0 if code == 0 else 2), result
        assert len(called.read_text().splitlines()) == (11 if code == 0 else 3)
        if code:
            assert 'wait for guidance' in result.stderr, result.stderr
            assert 'synthetic-command' not in result.stdout + result.stderr
    (directory / names[0]).unlink()
    result = subprocess.run(['bash', str(dispatcher)], input='{}',
                            text=True, capture_output=True)
    assert result.returncode == 2, result
    # Invoke the real secret hook directly with a failed detector. Synthetic
    # jq/python3 children cannot read credentials or run a real command.
    for name, body in [('jq', "printf 'synthetic-command'"), ('python3', 'exit 1')]:
        stub = directory / name
        stub.write_text('#!/bin/sh\n' + body + '\n')
        stub.chmod(0o700)
    env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ['PATH'])
    result = subprocess.run(
        ['bash', str(root / 'scripts/hook-block-secret-leak.sh')],
        input='{}', text=True, capture_output=True, env=env)
    assert result.returncode == 2, result
    assert 'wait for guidance' in result.stderr, result.stderr
print('dispatcher: success, refusal, detector failure, missing child: passed')
PY
