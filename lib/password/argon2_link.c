/* Keep libargon2 in the bytecode stub's dependency list. Upstream argon2 uses
   ctypes' global symbol lookup but only adds native linker flags. */
#include <argon2.h>
#include <caml/mlvalues.h>
CAMLprim value httpkit_argon2_link(value unit) {
  (void)unit;
  return Val_bool(argon2_type2string(Argon2_id, 0) != NULL);
}
