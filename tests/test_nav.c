/* Navigation fixture: reproduces the "a -> {b, c}, b -> {e..i}" layout where b's
 * subtree occupies a tall region and pushes c out of the visible viewport.
 * Vertical movement (j/k) from b should land on c (same column, b's sibling),
 * not on b's child e (right column, geometrically closer but off-axis).
 */

static int i(void)
{
    return 0;
}

static int h(void)
{
    return 0;
}

static int g(void)
{
    return 0;
}

static int f(void)
{
    return 0;
}

static int e(void)
{
    return i();
}

static int c(void)
{
    return 0;
}

static int b(void)
{
    e();
    f();
    g();
    h();
    i();
    return 0;
}

static int a(void)
{
    b();
    c();
    return 0;
}

int main(void)
{
    a();
    return 0;
}
