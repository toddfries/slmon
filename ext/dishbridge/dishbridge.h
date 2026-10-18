#ifndef SLMON_DISHBRIDGE_H
#define SLMON_DISHBRIDGE_H

/* out and err are malloc'd C strings. Caller frees them.
 * Returns 0 on success, -1 on failure. */
#ifdef __cplusplus
extern "C" {
#endif
int slmon_dish_call(const char *target, const char *op, char **out, char **err);
#ifdef __cplusplus
}
#endif

#endif
