#define _GNU_SOURCE
#include "CLinuxShims.h"

#ifdef __linux__
#include <errno.h>
#include <spawn.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1 << 0)
#endif

int metagent_renameat_noreplace(int olddirfd, const char *oldpath, int newdirfd, const char *newpath) {
    return (int)syscall(SYS_renameat2, olddirfd, oldpath, newdirfd, newpath, RENAME_NOREPLACE);
}

int metagent_spawn_file_actions_addchdir(posix_spawn_file_actions_t *actions, const char *path) {
    return posix_spawn_file_actions_addchdir_np(actions, path);
}

int metagent_spawn_file_actions_addclosefrom(posix_spawn_file_actions_t *actions, int lowfd) {
    return posix_spawn_file_actions_addclosefrom_np(actions, lowfd);
}

int metagent_pidfd_open(int pid) {
#ifdef SYS_pidfd_open
    return (int)syscall(SYS_pidfd_open, pid, 0);
#else
    errno = ENOSYS;
    return -1;
#endif
}
#endif
