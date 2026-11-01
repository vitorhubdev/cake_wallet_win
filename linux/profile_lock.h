#ifndef CAKE_PC_LINUX_PROFILE_LOCK_H_
#define CAKE_PC_LINUX_PROFILE_LOCK_H_

#include <cerrno>
#include <fcntl.h>
#include <filesystem>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

// The lock belongs to the data directory, not an executable or desktop session.
// Never unlink it on exit: another process may already hold the same inode.
class ProfileLock {
 public:
  ProfileLock() = default;
  ProfileLock(const ProfileLock&) = delete;
  ProfileLock& operator=(const ProfileLock&) = delete;
  ~ProfileLock() { Release(); }

  int Acquire(const std::filesystem::path& directory) {
    if (descriptor_ != -1) return EALREADY;
    std::error_code error;
    const bool created = std::filesystem::create_directories(directory, error);
    if (error) return error.value();
    if (created && ::chmod(directory.c_str(), S_IRWXU) != 0) return errno;
    const auto path = directory / ".cake-wallet.lock";
    const int descriptor = ::open(path.c_str(), O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor == -1) return errno;
    struct stat metadata;
    if (::fstat(descriptor, &metadata) != 0 || !S_ISREG(metadata.st_mode) ||
        metadata.st_uid != ::geteuid()) {
      ::close(descriptor);
      return EACCES;
    }
    if (::flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
      const int status = errno;
      ::close(descriptor);
      return status;
    }
    descriptor_ = descriptor;
    return 0;
  }

  void Release() {
    if (descriptor_ != -1) {
      ::close(descriptor_);
      descriptor_ = -1;
    }
  }

 private:
  int descriptor_ = -1;
};
#endif
