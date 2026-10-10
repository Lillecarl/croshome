#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--version") == 0) {
    printf("greet %s\n", VERSION);
    return 0;
  }
  printf("Hello, %s!\n", argc > 1 ? argv[1] : "world");
  return 0;
}
