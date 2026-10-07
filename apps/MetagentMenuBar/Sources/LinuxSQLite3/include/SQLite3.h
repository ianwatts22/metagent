// Linux stand-in for the macOS SDK `SQLite3` module, so core sources keep a
// single `import SQLite3`. It re-exports the SQLite amalgamation Swift ships
// for its own toolchain, which links statically and needs no system library.
#include <sqlite3.h>
