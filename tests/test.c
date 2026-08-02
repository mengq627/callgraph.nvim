#include <stdio.h>

static int func_l2_c ()
{
    return 0;
}


static int func_l2_a ()
{
    func_l2_c();
    return 0;
}static int func_l2_b ()
{
    func_l2_c();
    return 0;
}


static int func_l1_a ()
{
    func_l2_a();
    return 0;
}

static int func_l1_b ()
{
    func_l2_b();
    return 0;
}

int main ()
{
    func_l1_a();
    func_l1_b();
    return 0;
    
}
