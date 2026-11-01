import unittest

from automation.python_versions import compatible


class PythonVersionTests(unittest.TestCase):
    def test_standard_numeric_constraints(self):
        for version, constraint, expected in (
            ('3.13.18', '>=3.11,<4.0', True), ('3.13.18', '>=3.14', False),
            ('3.13.18', '~=3.13', True), ('3.14.0', '~=3.13', True),
            ('4.0.0', '~=3.13', False), ('3.14.0', '~=3.13.1', False),
            ('3.13.0', '~=3.13.1', False), ('3.13.18', '~=3.13.1', True),
            ('3.13.18', '>=3.13, !=3.13.18', False), ('3.13.19', '!=3.13.18', True),
            ('3.13.18', '==3.13.*', True), ('3.14.0', '==3.13.*', False),
            ('3.13.18', '!=3.13.*', False), ('3.14.0', '!=3.13.*', True),
            ('3.13.0', '==3.13', True), ('3.13.18', '==3.13', False),
        ):
            with self.subTest(version=version, constraint=constraint):
                self.assertEqual(compatible(version, constraint), expected)

    def test_unsupported_constraints_are_never_silently_accepted(self):
        for constraint in ('~=3', '>=3.13.*', '===custom', '>=3.14,invalid', '', '>=3.13 || <4'):
            with self.subTest(constraint=constraint), self.assertRaises(ValueError):
                compatible('3.13.18', constraint)
