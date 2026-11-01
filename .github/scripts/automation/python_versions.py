import re


def compatible(version, constraint):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError(f'Invalid stable Python version: {version}')
    current = tuple(map(int, version.split('.')))
    bounds = []
    for bound in constraint.split(','):
        match = re.fullmatch(r'\s*(~=|!=|>=|<=|>|<|==)\s*([0-9]+(?:\.[0-9]+){0,2})(\.\*)?\s*', bound)
        if match is None:
            raise ValueError(f'Unsupported upstream Python constraint: {constraint}')
        operator, text, wildcard = match.groups()
        prefix = tuple(map(int, text.split('.')))
        if (wildcard and operator not in ('==', '!=')) or (operator == '~=' and len(prefix) < 2):
            raise ValueError(f'Unsupported upstream Python constraint: {constraint}')
        other = prefix + (0,) * (3 - len(prefix))
        bounds.append((operator, prefix, other, wildcard))
    for operator, prefix, other, wildcard in bounds:
        if wildcard:
            equal = current[:len(prefix)] == prefix
            passes = equal if operator == '==' else not equal
        elif operator == '~=':
            passes = current >= other and current[:len(prefix) - 1] == prefix[:-1]
        else:
            passes = {'>=': current >= other, '<=': current <= other, '>': current > other,
                      '<': current < other, '==': current == other, '!=': current != other}[operator]
        if not passes:
            return False
    return True
