#!/usr/bin/env python3
"""Compile every SVG while preserving paths and detecting missing outputs."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

def main():
    count = 0
    for source, destination in [(ROOT/'res/pictures', ROOT/'assets/new-ui'), (ROOT/'assets', ROOT/'assets')]:
        files = sorted(source.rglob('*.svg'))
        if not files:
            raise RuntimeError(f'No SVG source files in {source}')
        with tempfile.TemporaryDirectory(prefix='cake-pc-svg-') as folder:
            stage = Path(folder)
            for original in files:
                target = stage/original.relative_to(source)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(original, target)
            # --out-dir flattens nested paths in the pinned compiler; never use it.
            subprocess.run(['dart', 'run', 'vector_graphics_compiler', '--input-dir', str(stage)],
                           cwd=ROOT, check=True, timeout=600)
            for original in files:
                relative = original.relative_to(source)
                compiled = stage/(str(relative) + '.vec')
                if not compiled.is_file() or compiled.stat().st_size == 0:
                    raise RuntimeError(f'Missing vector output: {relative}')
                target = destination/(str(relative) + '.vec')
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(compiled, target)
                count += 1
    print(f'Verified {count} compiled SVG outputs; paths preserved.')

if __name__ == '__main__':
    main()
