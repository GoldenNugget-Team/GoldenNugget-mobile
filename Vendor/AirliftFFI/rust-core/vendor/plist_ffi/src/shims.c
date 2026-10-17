// Jackson Coxson
// We unfortunately must wait for VaList to be stabalized

#include "../plist.h"
#include <stdint.h>
#include <stdlib.h>

plist_t plist_access_path(plist_t plist, uint32_t length, ...) {
  const void **path = malloc(sizeof(void *) * length);
  if (!path)
    return NULL;

  va_list args;
  va_start(args, length);
  for (uint32_t i = 0; i < length; ++i) {
    path[i] = va_arg(args, const void *);
  }
  va_end(args);

  plist_t result = plist_access_path_shim(plist, length, path);
  free(path);
  return result;
}

plist_t plist_access_pathv(plist_t plist, uint32_t length, va_list v) {
  const void **path = malloc(sizeof(void *) * length);
  if (!path)
    return NULL;

  for (uint32_t i = 0; i < length; ++i) {
    path[i] = va_arg(v, const void *);
  }

  plist_t result = plist_access_path_shim(plist, length, path);
  free(path);
  return result;
}
