/* cwbh-ffi — the C ABI the LÖVE client loads with LuaJIT's ffi.load.
 *
 * Kept byte-identical to the ffi.cdef block in love2d/src/wallet.lua.
 * Every char* returned here is owned by the caller and must be released with
 * cwbh_string_free, which is the only allocator that matches.
 */
#ifndef CWBH_H
#define CWBH_H

#ifdef __cplusplus
extern "C" {
#endif

int   cwbh_abi_version(void);
char *cwbh_version(void);
char *cwbh_describe(void);
char *cwbh_execute(const char *request_json);
void  cwbh_string_free(char *s);

#ifdef __cplusplus
}
#endif
#endif /* CWBH_H */
