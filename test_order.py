import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time


repo = Path(__file__).resolve().parent
ansi = re.compile(r'\x1b\]0;[^\x07]*\x07|\x1b\[[0-9;]*m')
orders = ['model cache project diff ctx 5h 7d', '7d 5h ctx diff project cache model', 'ctx']
with tempfile.TemporaryDirectory(prefix='statusline-order-') as tmp:
    home = Path(tmp)
    state = home / '.claude'
    state.mkdir()
    env = dict(os.environ, USERPROFILE=str(home), HOME=home.as_posix())
    data = dict(model=dict(display_name='Test'), effort=dict(level='max'), workspace=dict(project_dir='/test/project'), transcript_path=(state / 'order.jsonl').as_posix(), context_window=dict(used_percentage=5, context_window_size=1000000), rate_limits=dict(five_hour=dict(used_percentage=18), seven_day=dict(used_percentage=34)))
    for ext, command in [('ps1', [shutil.which('pwsh'), '-NoProfile', '-File']), ('sh', [shutil.which('bash')])]:
        source = (repo / f'statusline.{ext}').read_text(encoding='utf-8')
        for width, branch, tracked in [(140, 'main', True), (80, 'master', True), (140, 'feature/test', True), (80, '', False)]:
            baseline = None
            for order in orders:
                now = int(time.time())
                cache = dict(computed_at=now + 60, has_agents=False, cache_epoch=now, cache_ttl=300, agents=[], lines_add=12, lines_del=3, branch=branch, in_git=tracked)
                (state / '.sl_compute_order').write_text(json.dumps(cache))
                if ext == 'ps1':
                    patched = re.sub(r'(?m)^\$SEGMENT_ORDER = .*', '$SEGMENT_ORDER = @(' + ', '.join(repr(key) for key in order.split()) + ')', source)
                    patched = re.sub(r'(?m)^\$WIDTH\s*=\s*\d+', f'$WIDTH = {width}', patched)
                else:
                    patched = re.sub(r'(?m)^SEGMENT_ORDER=.*', 'SEGMENT_ORDER=(' + order.upper() + ')', source)
                    patched = re.sub(r'(?m)^WIDTH=\d+', f'WIDTH={width}', patched)
                script = home / f'check.{ext}'
                script.write_text(patched, encoding='utf-8', newline='\n')
                result = subprocess.run(command + [str(script)], input=json.dumps(data), text=True, encoding='utf-8', capture_output=True, env=env, timeout=30, check=True)
                line = ansi.sub('', result.stdout).splitlines()[0]
                parts = re.sub(r'\d+m\d+s', 'TIMER', line).split(' | ')
                assert len(line) <= width - 4, line
                if order == orders[0]:
                    baseline = parts
                    assert re.search(r'Test (?:\[1M\] )?max \|', line) and '(max)' not in line, line
                    assert ('🟢 📁' if tracked else '⚪ 📁') in line, line
                    assert '(main)' not in line and '(master)' not in line and '(untracked)' not in line, line
                    if branch == 'feature/test':
                        assert '(feature/test)' in line, line
                    assert re.search(r'cache \d+m\d+s \| [🟢⚪] 📁|\| \d+m\d+s \| [🟢⚪] 📁', line), line
                elif order == orders[1]:
                    assert parts == baseline[::-1], (baseline, parts)
                else:
                    assert len(parts) == 1 and parts[0].startswith('50k '), line
            print(f'{ext}: reorder, omission and collapse at width {width} OK', flush=True)
