#ifndef METAGENT_C_LINUX_SHIMS_H
#define METAGENT_C_LINUX_SHIMS_H

// Linux system calls and libc details the Swift Glibc and Musl modules do
// not expose consistently.

#include <signal.h>
#include <spawn.h>

/// renameat2(RENAME_NOREPLACE): fails with EEXIST instead of replacing.
int metagent_renameat_noreplace(int olddirfd, const char *oldpath, int newdirfd, const char *newpath);

/// posix_spawn_file_actions_addchdir_np, which older glibc headers hide from Swift.
int metagent_spawn_file_actions_addchdir(posix_spawn_file_actions_t *actions, const char *path);

/// Closes every descriptor >= `lowfd` in a posix_spawn child, matching
/// Darwin's POSIX_SPAWN_CLOEXEC_DEFAULT for descriptors not explicitly mapped.
int metagent_spawn_file_actions_addclosefrom(posix_spawn_file_actions_t *actions, int lowfd);

/// pidfd_open(2); returns -1 with errno set when unsupported.
int metagent_pidfd_open(int pid);

/// Child pid and raw status from a waitid(2) result. glibc and musl spell
/// these siginfo_t fields through different unions.
int metagent_siginfo_pid(const siginfo_t *info);
int metagent_siginfo_status(const siginfo_t *info);

/// signal(SIGPIPE, SIG_IGN); SIG_IGN is a cast macro Swift cannot import on musl.
void metagent_ignore_sigpipe(void);

#endif
