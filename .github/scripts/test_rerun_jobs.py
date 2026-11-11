"""A retry retains successful jobs without hiding a newer failed execution."""
import unittest
from unittest.mock import Mock

from automation.jobs import latest_jobs


class RerunJobsTests(unittest.TestCase):
    def select(self, jobs):
        api = Mock()
        api.pages.return_value = jobs
        return latest_jobs(api, {'id': 100, 'run_attempt': 2})

    def job(self, name, attempt, conclusion):
        return {'name': name, 'run_attempt': attempt, 'conclusion': conclusion}

    def test_install_retry_retains_the_successful_package(self):
        package = self.job('package', 1, 'success')
        failed = self.job('assemble', 1, 'failure')
        passed = self.job('assemble', 2, 'success')
        for jobs in ([package, failed, passed], [passed, failed, package]):
            with self.subTest(jobs=jobs):
                self.assertCountEqual(self.select(jobs), [package, passed])

    def test_new_failure_replaces_an_older_success(self):
        passed = self.job('package', 1, 'success')
        failed = self.job('package', 2, 'failure')
        self.assertEqual(self.select([failed, passed]), [failed])

    def test_publisher_retry_reads_the_recorded_qualification_attempt(self):
        package = self.job('package', 1, 'success')
        publisher = self.job('publish', 2, 'failure')
        api = Mock()
        api.pages.return_value = [package, publisher]
        self.assertEqual(latest_jobs(api, {'id': 100, 'run_attempt': 1}, historical=True), [package])

    def test_duplicate_executions_and_invalid_attempts_are_rejected(self):
        package = self.job('package', 1, 'success')
        for jobs in ([package, package], [package, self.job('package', 2, 'success'), package],
                     [self.job('package', 0, 'success')], [self.job('package', 3, 'success')]):
            with self.subTest(jobs=jobs), self.assertRaises(ValueError):
                self.select(jobs)


if __name__ == '__main__':
    unittest.main()
