
#include <stdlib.h>
#include <lua.h>

void* custom_alloc(void* ud, void* ptr, size_t osize, size_t nsize) {
  if (nsize == 0) {
    free(ptr);
    return NULL;
  } else {
    return realloc(ptr, nsize);
  }
}

int main(void) {
  return lua_newstate(custom_alloc, NULL) ? 0 : 1;
}
