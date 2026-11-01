#!/usr/bin/env python3
"""Bounded wait for the pinned native artifact in this release's own Actions run."""
import argparse
import json
import os
import time
import urllib.error
import urllib.request


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact',required=True)
    parser.add_argument('--timeout',type=int,default=19800)
    args=parser.parse_args()
    repo=os.environ['GITHUB_REPOSITORY']
    run=os.environ['GITHUB_RUN_ID']
    if not run.isdecimal() or repo.count('/')!=1:
        raise ValueError('Unexpected repository/run identifier')
    token=os.environ['GH_TOKEN']
    base='https://api.github.com/repos/'+repo+'/actions/runs/'+run
    deadline=time.monotonic()+args.timeout
    while time.monotonic()<deadline:
        request=urllib.request.Request(base+'/artifacts?per_page=100',headers={
          'Authorization':'Bearer '+token,'Accept':'application/vnd.github+json',
          'User-Agent':'cake-wallet-pc-ci','X-GitHub-Api-Version':'2022-11-28'})
        try:
            with urllib.request.urlopen(request,timeout=30) as response:
                data=json.load(response)
            matches=[a for a in data['artifacts'] if a['name']==args.artifact and not a['expired']]
            if len(matches)==1:
                print('Native artifact is ready for the release run.',flush=True)
                return
            if len(matches)>1:
                raise RuntimeError('Ambiguous native artifact set')
        except urllib.error.HTTPError as error:
            if error.code not in (429,500,502,503,504): raise
        except (urllib.error.URLError,TimeoutError):
            pass
        time.sleep(20)
    raise TimeoutError('Native artifact did not become available within the CI deadline')

if __name__=='__main__': main()
