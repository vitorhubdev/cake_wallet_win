#include "../../linux/profile_lock.h"
#include <fstream>
#include <iostream>
#include <string>
#include <sys/wait.h>

int main() {
  char pattern[] = "/tmp/cake-pc-lock-XXXXXX";
  const auto temporary = ::mkdtemp(pattern);
  if (temporary == nullptr) return 1;
  const std::filesystem::path root = std::filesystem::path(temporary) / "carteira espaço";
  int result = 0;
  {
    ProfileLock first, second, independent;
    if (first.Acquire(root) != 0) result = 2;
    if (second.Acquire(root) != EWOULDBLOCK) result = 3;
    if (independent.Acquire(root / "independent") != 0) result = 4;
    // Verify a different process is excluded, not merely another class instance.
    const pid_t child = ::fork();
    if (child == 0) {
      ProfileLock other;
      ::_exit(other.Acquire(root) == EWOULDBLOCK ? 0 : 1);
    }
    if (child < 0) result = 5;
    else {
      int status = 0;
      if (::waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status)) result = 6;
    }
    first.Release();
    if (second.Acquire(root) != 0) result = 7;
  }
  {
    ProfileLock after_exit;
    if (after_exit.Acquire(root) != 0) result = 8;
  }
  const auto file = root / "not-a-directory";
  std::ofstream(file).put('x');
  {
    ProfileLock invalid;
    if (invalid.Acquire(file) == 0) result = 9;
  }
  std::filesystem::remove(root / ".cake-wallet.lock");
  std::filesystem::create_symlink(file, root / ".cake-wallet.lock");
  {
    ProfileLock symlink;
    if (symlink.Acquire(root) == 0) result = 10;
  }
  std::error_code ignored;
  std::filesystem::remove_all(temporary, ignored);
  if (result == 0) std::cout << "Linux lock, process exclusion, Unicode path, release, invalid path and symlink checks passed.\n";
  return result;
}
