"""Keep the latest execution of each job when only failed jobs are rerun."""


def latest_jobs(api, run, *, historical=False):
    latest = {}
    seen = set()
    for job in api.pages(f"actions/runs/{run['id']}/jobs?filter=all", 'jobs'):
        attempt = job['run_attempt']
        if historical and job['name'] == 'publish' and type(attempt) is int and attempt > run['run_attempt']:
            continue
        if type(attempt) is not int or not 1 <= attempt <= run['run_attempt']:
            raise ValueError('Qualification job belongs to a different attempt')
        identity = (job['name'], attempt)
        if identity in seen:
            raise ValueError(f"Duplicate qualification job: {job['name']}")
        seen.add(identity)
        previous = latest.get(job['name'])
        if previous is None or previous['run_attempt'] < attempt:
            latest[job['name']] = job
    return list(latest.values())
