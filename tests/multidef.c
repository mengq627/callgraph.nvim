/* Multi-definition fixture: `impl` is defined twice under conditional
 * compilation, so a cscope index records TWO definitions for it. `caller`
 * calls `impl`. In the callgraph: expand `caller` -> `impl`, then expand
 * `impl` — the plugin should pop the definition picker (a.c-like file vs
 * this one). Requires a cscope.out generated from this repo:
 *
 *   cscope -bq        (from the repo root, or wherever cscope.out lives)
 *   sources = { 'cscope' }
 */

#ifdef USE_V2
static int impl(void)
{
    return 2;
}
#else
static int impl(void)
{
    return 1;
}
#endif

static int caller(void)
{
    return impl();
}

int main(void)
{
    return caller();
}
