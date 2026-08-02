/* Include libssh2 by NAME, not by path.
 *
 * The module map used to name /usr/include/libssh2.h directly, which is where
 * Debian's libssh2-1-dev puts it and nowhere else: Homebrew installs to
 * /opt/homebrew/include on Apple Silicon and /usr/local/include on Intel, so
 * every macOS build failed while parsing the module map — before compiling a
 * line. A relative shim plus pkg-config lets the toolchain supply the search
 * path per platform.
 */
#include <libssh2.h>
