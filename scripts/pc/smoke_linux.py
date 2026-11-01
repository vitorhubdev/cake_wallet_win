#!/usr/bin/env python3
"""Launch only disposable CI profiles; check real window/process and exclusion."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

def check(condition: bool, message: str) -> None:
    if not condition: raise RuntimeError(message)

def main() -> None:
    check(os.getenv('GITHUB_ACTIONS')=='true' and os.getenv('RUNNER_ENVIRONMENT')=='github-hosted',
          'Linux launch tests require a disposable GitHub-hosted runner')
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('launcher',type=Path)
    parser.add_argument('--profile',type=Path)
    args=parser.parse_args()
    launcher=args.launcher.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='cake-pc-smoke-') as temporary:
        profile=(args.profile.resolve() if args.profile else Path(temporary)/'perfil com espaço')
        if args.profile:
            check(str(profile).startswith(str(Path(os.environ['RUNNER_TEMP']).resolve())+os.sep),
                  'Explicit smoke profile must be in this runner temporary directory')
        environment=dict(os.environ,CAKE_WALLET_DIR=str(profile),LIBGL_ALWAYS_SOFTWARE='1',GDK_BACKEND='x11')
        process=None
        try:
            # Drain diagnostics to a private file, never publish arbitrary native output.
            with tempfile.TemporaryFile() as diagnostics:
                process=subprocess.Popen([str(launcher)],env=environment,cwd='/',stdout=diagnostics,stderr=diagnostics)
                deadline=time.monotonic()+30
                while time.monotonic()<deadline:
                    check(process.poll() is None,'Packaged Linux application exited during startup')
                    windows=subprocess.run(['xdotool','search','--onlyvisible','--pid',str(process.pid)],text=True,capture_output=True,timeout=5)
                    if windows.returncode==0 and windows.stdout.strip(): break
                    time.sleep(0.5)
                else: raise RuntimeError('Packaged Linux application did not create a visible window')
                check((profile/'.cake-wallet.lock').is_file(),'Native profile lock was not created')
                duplicate=subprocess.run([str(launcher)],env=environment,cwd='/',stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
                check(duplicate.returncode==0,'Second launch did not exit safely')
                check(process.poll() is None,'Second launch disturbed the original process')
                print(json.dumps({'status':'passed','nativeLaunch':True,'visibleWindow':True,
                    'unicodeProfile':True,'workingDirectoryIndependent':True,'duplicateRejected':True,
                    'scope':'process/visible-window checks; real onboarding is checked separately'}))
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill();process.wait(timeout=5)

if __name__=='__main__': main()
