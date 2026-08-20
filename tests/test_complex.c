#include <stdio.h>

/* A deliberately complex call-graph fixture covering the relationship shapes
 * the plugin must handle:
 *   - diamond (multiple paths to one function)
 *   - self-recursion (cycle)
 *   - mutual recursion (cycle)
 *   - fan-out (one function calls many)
 *   - deep chains
 *   - a shared leaf reached from several roots
 */

/* ---- shared leaf, reached from many places ---- */
static int leaf_common(void)
{
    return 0;
}

/* ---- diamond: alpha & beta both call shared, which calls leaf_common ---- */
static int shared(void)
{
    return leaf_common();
}

static int alpha(void)
{
    return shared();
}

static int beta(void)
{
    return shared();
}

/* ---- deep chain ---- */
static int chain4(void)
{
    return leaf_common();
}

static int chain3(void)
{
    return chain4();
}

static int chain2(void)
{
    return chain3();
}

static int chain1(void)
{
    return chain2();
}

/* ---- fan-out: fan calls several functions ---- */
static int fan_a(void)
{
    return leaf_common();
}

static int fan_b(void)
{
    return chain1();
}

static int fan(void)
{
    fan_a();
    fan_b();
    return 0;
}

/* ---- self-recursion ---- */
static int recursive(int n)
{
    if (n <= 0)
        return 0;
    return recursive(n - 1);
}

/* ---- mutual recursion (cycle) ---- */
static int even(int n);

static int odd(int n)
{
    if (n <= 0)
        return 0;
    return even(n - 1);
}

static int even(int n)
{
    if (n <= 0)
        return 0;
    return odd(n - 1);
}

int main(void)
{
    alpha();
    beta();
    chain1();
    fan();
    recursive(3);
    even(2);
    return 0;
}
