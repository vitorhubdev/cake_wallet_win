#ifndef CAKE_WINDOWS_PROFILE_LOCK_H_
#define CAKE_WINDOWS_PROFILE_LOCK_H_

#include <windows.h>
#include <filesystem>
#include <system_error>

// Lock the actual data directory, including across desktop sessions and copies
// of the portable executable. A crash releases the OS handle; the empty file
// is deliberately retained so there is no unlink/recreate race.
class ProfileLock {
 public:
  ProfileLock() = default;
  ProfileLock(const ProfileLock&) = delete;
  ProfileLock& operator=(const ProfileLock&) = delete;
  ~ProfileLock() { Release(); }

  DWORD Acquire(const std::filesystem::path& directory) {
    if (handle_ != INVALID_HANDLE_VALUE) return ERROR_ALREADY_EXISTS;
    std::error_code error;
    std::filesystem::create_directories(directory, error);
    if (error) return static_cast<DWORD>(error.value());
    handle_ = ::CreateFileW((directory / L".cake-wallet.lock").c_str(),
                           GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_HIDDEN, nullptr);
    return handle_ == INVALID_HANDLE_VALUE ? ::GetLastError() : ERROR_SUCCESS;
  }

  void Release() {
    if (handle_ != INVALID_HANDLE_VALUE) {
      ::CloseHandle(handle_);
      handle_ = INVALID_HANDLE_VALUE;
    }
  }

 private:
  HANDLE handle_ = INVALID_HANDLE_VALUE;
};
#endif
