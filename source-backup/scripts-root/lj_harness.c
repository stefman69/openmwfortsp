#include <stdio.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
int main(int argc, char** argv) {
  if (argc < 2) { printf("usage: harness script.lua [n]\n"); return 2; }
  lua_State* L = luaL_newstate();
  if (L == NULL) { printf("HARNESS: luaL_newstate failed\n"); return 1; }
  luaL_openlibs(L);
  lua_newtable(L);
  if (argc > 2) { lua_pushstring(L, argv[2]); lua_rawseti(L, -2, 1); }
  lua_setglobal(L, "arg");
  if (luaL_loadfile(L, argv[1]) != 0) { printf("HARNESS load error: %s\n", lua_tostring(L, -1)); return 1; }
  if (lua_pcall(L, 0, 0, 0) != 0) { printf("HARNESS run error: %s\n", lua_tostring(L, -1)); return 1; }
  lua_close(L);
  return 0;
}
