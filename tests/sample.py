"""Call-graph fixture for the non-C language-agnostic integration test.

Same relationship shapes as test_complex.c so the language-agnostic claim is
exercised against a server whose language is not C:
  - diamond (alpha & beta both call shared)
  - a shared leaf reached from several places
  - a deep chain (main -> chain1 -> chain2 -> leaf_common)
  - self-recursion
"""


def leaf_common():
    return 0


def shared():
    return leaf_common()


def alpha():
    return shared()


def beta():
    return shared()


def chain2():
    return leaf_common()


def chain1():
    return chain2()


def recursive(n):
    if n <= 0:
        return 0
    return recursive(n - 1)


def main():
    alpha()
    beta()
    chain1()
    recursive(2)


class Greeter:
    """Class-method calls: methods call each other and module functions."""

    def greet(self):
        return shared()

    def greet_many(self, n):
        return [self.greet() for _ in range(n)]

    def run(self):
        return self.greet_many(2)


def build_greeter():
    return Greeter()
