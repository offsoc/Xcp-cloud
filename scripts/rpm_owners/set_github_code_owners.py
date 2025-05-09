#!/usr/bin/env python3

import argparse
import difflib
import json
import os
import re
import sys
from contextlib import suppress
from subprocess import check_output

import github as gh
from github.Repository import Repository

BRANCHES = ['master']
CODEOWNERS = '.github/CODEOWNERS'
USER = check_output(['git', 'config', 'user.name']).decode().strip()
EMAIL = check_output(['git', 'config', 'user.email']).decode().strip()
assert USER and len(USER.splitlines()) == 1
assert EMAIL and len(EMAIL.splitlines()) == 1
MESSAGE = f"""Set team owner

Signed-off-by: {USER} <{EMAIL}>
"""

def to_gh_team(maintainer: str):
    return '@xcp-ng-rpms/' + re.sub(r'\W+', '-', maintainer.lower())


def diff(current, expected):
    return '\n'.join(
        difflib.unified_diff(
            current.splitlines() if current is not None else [],
            expected.splitlines(),
            f'current/{CODEOWNERS}',
            f'expected/{CODEOWNERS}',
            lineterm='',
        )
    )


def set_gh_code_owners(repo: Repository, rpm, force: bool) -> bool:
    owners = [rpm['maintainer']]
    # make sure the platform team is owner of all the repositories
    if 'OS Platform & Release' not in owners:
        owners.append('OS Platform & Release')
    content = '* ' + ' '.join(to_gh_team(owner) for owner in owners) + '\n'
    ok = True
    for branch in BRANCHES:
        current_content = None
        current_content_sha = ''
        with suppress(gh.UnknownObjectException):
            gh_content = repo.get_contents(CODEOWNERS, branch)
            current_content_sha = gh_content.sha  # type: ignore
            current_content = gh_content.decoded_content.decode()  # type: ignore
        if current_content is None:
            print(f'creating {pkg} CODEOWNERS file in {branch}...', end='', file=sys.stderr, flush=True)
            repo.create_file(CODEOWNERS, MESSAGE, content, branch)
            print(' done', file=sys.stderr)
        elif force and current_content != content:
            print(f'updating {pkg} CODEOWNERS file in {branch}...', end='', file=sys.stderr, flush=True)
            repo.update_file(CODEOWNERS, MESSAGE, content, current_content_sha, branch)
            print(' done', file=sys.stderr)
        elif current_content == content:
            print(f'{pkg} CODEOWNERS is already OK in {branch}', file=sys.stderr, flush=True)
        else:
            print(f'error: {pkg} CODEOWNERS is not synced in {branch}', file=sys.stderr, flush=True)
            print(diff(current_content, content))
            ok = False
    return ok


parser = argparse.ArgumentParser(
    description="Set the code owner for the rpm repositories based on the packages.json file"
)
parser.add_argument('--force', help="Set the CODEOWNERS even if the file already exists", action='store_true')
args = parser.parse_args()

# load the rpm data from the ref file
with open('packages.json') as f:
    rpms = json.load(f)

auth = gh.Auth.Token(os.environ['GITHUB_TOKEN'])
g = gh.Github(auth=auth)
org = g.get_organization('xcp-ng-rpms')

gh_repos = dict((r.name, r) for r in org.get_repos())

# # do we have the same list of repositories than packages?
# missing_repos = set(rpms.keys()) - set(gh_repos.keys())
# print(missing_repos)

# # do we have repos without package?
# missing_pkgs = set(gh_repos.keys()) - set(rpms.keys())
# print(missing_repos)

pkgs = set(gh_repos.keys()).intersection(set(rpms.keys()))

ok = True
for pkg in pkgs:
    repo = gh_repos[pkg]
    rpm = rpms[pkg]
    ok &= set_gh_code_owners(repo, rpm, args.force)
if not ok:
    exit(1)
