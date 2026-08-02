#include <stdio.h>

static int add(int a, int b) {
    return a + b;
}

static int twice(int x) {
    return add(x, x);
}

int main(void) {
    int y = twice(21);
    int z = add(y, 1);
    printf("%d\n", z);
    return 0;
}
