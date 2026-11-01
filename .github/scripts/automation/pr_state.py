import json
import re
import time

MARKER = '<!-- immich-windows:automatic-upstream:v1 -->'
SHA = re.compile(r'[0-9a-f]{40}')
OWNERSHIP = re.compile(r'<!-- immich-windows:automatic-head ([0-9a-f]{40}) base ([0-9a-f]{40}) -->')
PENDING = re.compile(r'<!-- immich-windows:pending-head ([0-9a-f]{40}) base ([0-9a-f]{40}) -->')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_pr(api, pr, branch, version, upstream_commit):
    require(pr['base']['ref'] == 'main' and pr['base']['repo']['full_name'] == api.repo
            and pr['head'].get('repo') and pr['head']['repo']['full_name'] == api.repo
            and pr['head']['ref'] == branch, 'Update PR repository/branch identity changed')
    require(pr.get('user', {}).get('login') == 'github-actions[bot]', 'Automatic PR was not created by the repository workflow')
    require(MARKER in (pr.get('body') or ''), 'An unrelated PR uses the automatic update branch; inspect it manually')
    head = pr['head']['sha']
    require(SHA.fullmatch(head), 'Invalid update PR head')
    owner = OWNERSHIP.findall(pr.get('body') or '')
    require(len(owner) == 1 and owner[0][0] == head, 'Automatic PR head changed outside this workflow; refusing to overwrite it')
    pin = json.loads(api.file('upstream.json', head))
    require(pin['version'] == version and pin['commit'] == upstream_commit and type(pin.get('windowsRevision')) is int
            and pin['windowsRevision'] == 0, 'Existing automatic PR does not contain the expected upstream revision zero')


def prepared_pr(api, number, head, base):
    for attempt in range(6):
        pr = api.get(f'pulls/{number}')
        if (pr['head']['sha'] == head and pr['base']['sha'] == base
                and OWNERSHIP.findall(pr.get('body') or '') == [(head, base)]):
            return pr
        if attempt < 5:
            time.sleep(2)
    raise ValueError('GitHub has not confirmed the prepared PR head/base; the next scheduled check will resume')


def pending_body(body, head, base):
    return PENDING.sub('', body).rstrip() + f'\n<!-- immich-windows:pending-head {head} base {base} -->\n'


def recover_pr_update(api, pr, branch, version, upstream_commit):
    owners = OWNERSHIP.findall(pr.get('body') or '')
    pending = PENDING.findall(pr.get('body') or '')
    if len(owners) != 1 or owners[0][0] == pr['head']['sha'] or not pending:
        return pr
    require(len(pending) == 1 and pending[0][0] == pr['head']['sha'],
            'Pending automatic update does not identify the current PR head')
    head, base = pending[0]
    prior = dict(pr, head=dict(pr['head'], sha=owners[0][0]))
    validate_pr(api, prior, branch, version, upstream_commit)
    source = api.get('git/commits/' + head)
    require(source['sha'] == head and [parent['sha'] for parent in source['parents']] == [owners[0][0], base],
            'Pending automatic commit does not preserve its recorded parents')
    require(api.get('git/ref/heads/' + branch)['object']['sha'] == head,
            'Automatic branch changed before interrupted update recovery')
    body = OWNERSHIP.sub(f'<!-- immich-windows:automatic-head {head} base {base} -->',
                         PENDING.sub('', pr['body']).rstrip())
    api.write('PATCH', f"pulls/{pr['number']}", {'body': body})
    recovered = dict(pr, body=body)
    validate_pr(api, recovered, branch, version, upstream_commit)
    return recovered
