# The sqlite3 gem's own extconf cannot be used here.  rbwasm builds gem
# extensions outside Ruby's build tree, where mkmf cannot link a conftest at
# all -- even `have_func("rb_enc_raise")` comes back false -- so the gem's
# `find_library` check aborts.  Inside Ruby's own ext tree mkmf works, so this
# extension is built as a bundled one against a libsqlite3.a that was compiled
# for wasm32-wasi beforehand.  SQLite has handled `__wasi__` itself since
# 3.41, so the amalgamation needs no patching.
require "mkmf"

here = __dir__

$INCFLAGS << " -I#{here}"
$LDFLAGS << " -L#{here}"
$libs = append_library($libs, "sqlite3")

append_cflags("-fvisibility=hidden")

abort_missing = ->(what) { abort("\nCould not find #{what}.\n\n") }

abort_missing["sqlite3.h"] unless have_header("sqlite3.h")
unless have_library("sqlite3", "sqlite3_libversion_number", "sqlite3.h")
  abort_missing["libsqlite3"]
end

have_func("rb_enc_interned_str_cstr")
have_func("rb_proc_arity")
have_func("rb_integer_pack")

# Compiled with SQLITE_OMIT_LOAD_EXTENSION, so the load_extension pair is
# expected to come back false and the gem's own guards take over.
have_func("sqlite3_initialize")
have_func("sqlite3_backup_init")
have_func("sqlite3_column_database_name")
have_func("sqlite3_enable_load_extension")
have_func("sqlite3_load_extension")

abort("\nsqlite3_open_v2 is missing; SQLite >= 3.5.0 is required.\n\n") unless have_func("sqlite3_open_v2")

have_func("sqlite3_prepare_v2")
have_func("sqlite3_db_name", "sqlite3.h")
have_func("sqlite3_error_offset", "sqlite3.h")

have_type("sqlite3_int64", "sqlite3.h")
have_type("sqlite3_uint64", "sqlite3.h")

# Inside Ruby's ext tree mkmf writes the HAVE_* macros into extconf.h instead
# of passing them as -D, and clearing $extconf_h does not help: create_makefile
# does `create_header if $extmk and not $extconf_h`.
#
# backup.c tests HAVE_SQLITE3_BACKUP_INIT on its very first line and includes
# sqlite3_ruby.h only inside that guard, so it never reads extconf.h and
# compiles to an empty object -- leaving init_sqlite3_backup undefined at link
# time, while sqlite3.c (which includes headers first) still calls it.  The
# gem's own build passes -D, so put the macros on the command line as well.
# extconf.h repeats them with identical values, which is harmless.
$CPPFLAGS << " " << $defs.join(" ")

create_makefile("sqlite3/sqlite3_native")
