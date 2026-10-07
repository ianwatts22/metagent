#define _GNU_SOURCE
#include "CLinuxShims.h"

#ifdef __linux__
#include <dirent.h>
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
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
#ifdef __GLIBC__
    return posix_spawn_file_actions_addclosefrom_np(actions, lowfd);
#else
    // musl has no closefrom action. Close every descriptor open right now;
    // musl's child ignores close errors, so one closed in the meantime is fine.
    DIR *directory = opendir("/proc/self/fd");
    if (directory == NULL) return errno;
    int skip = dirfd(directory);
    int result = 0;
    struct dirent *entry;
    while (result == 0 && (entry = readdir(directory)) != NULL) {
        if (entry->d_name[0] < '0' || entry->d_name[0] > '9') continue;
        int descriptor = atoi(entry->d_name);
        if (descriptor >= lowfd && descriptor != skip) {
            result = posix_spawn_file_actions_addclose(actions, descriptor);
        }
    }
    closedir(directory);
    return result;
#endif
}

int metagent_pidfd_open(int pid) {
#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434
#endif
    return (int)syscall(SYS_pidfd_open, pid, 0);
}

int metagent_siginfo_pid(const siginfo_t *info) {
    return info->si_pid;
}

int metagent_siginfo_status(const siginfo_t *info) {
    return info->si_status;
}

void metagent_ignore_sigpipe(void) {
    signal(SIGPIPE, SIG_IGN);
}
#endif
