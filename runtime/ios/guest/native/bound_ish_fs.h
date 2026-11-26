#ifndef DSH_IOS_BOUND_ISH_FS_H
#define DSH_IOS_BOUND_ISH_FS_H
#include "bound_file.h"
#include "kernel/fs.h"
// Trusted App initialization only, before guest tasks run. Ownership transfers
// on success. Caller validates roots do not overlap .dsh/App state and chooses
// strict/image constructor. Fixed projected guest UID/GID are supplied, never
// copied from host ownership.
int dsh_bound_mount(const char *point, dsh_root *root, uid_t_ uid, uid_t_ gid);
// Trusted App initialization/teardown only, with no guest task running: undo
// one dsh_bound_mount() for the same guest-absolute point (trailing slashes
// are tolerated, dot segments are not). Root ownership was transferred by the
// mount, so the root is freed here and must not be freed again by the caller.
// Returns 0 once unmounted, _ENOENT when nothing is bound on that point (a
// repeated call is therefore a no-op), _EBUSY when a different mount occupies
// the point or the vfs still holds references to this one, otherwise the
// kernel's negative errno.
int dsh_bound_unmount(const char *point);
#endif
