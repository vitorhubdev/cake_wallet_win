#include "../../windows/runner/profile_lock.h"
#include <iostream>
#include <fstream>
#include <string>

int main() {
  wchar_t temp[MAX_PATH + 1];
  if (::GetTempPathW(MAX_PATH, temp) == 0) return 1;
  const auto root = std::filesystem::path(temp) /
      (L"Cake teste espaço-" + std::to_wstring(::GetCurrentProcessId()) + L"-" + std::to_wstring(::GetTickCount64()));
  int result = 0;
  {
    ProfileLock first;
    ProfileLock second;
    ProfileLock other;
    if (first.Acquire(root) != ERROR_SUCCESS) result = 2;
    if (second.Acquire(root) != ERROR_SHARING_VIOLATION) result = 3;
    if (other.Acquire(root / L"independent") != ERROR_SUCCESS) result = 4;
    first.Release();
    if (second.Acquire(root) != ERROR_SUCCESS) result = 5;
  }
  {
    ProfileLock after_exit;
    if (after_exit.Acquire(root) != ERROR_SUCCESS) result = 6;
  }
  const auto file_path = root / L"not-a-directory";
  std::ofstream(file_path).put('x');
  {
    ProfileLock invalid;
    if (invalid.Acquire(file_path) == ERROR_SUCCESS) result = 7;
  }
  std::error_code error;
  std::filesystem::remove_all(root, error);
  if (result == 0) std::cout << "Profile locking, exclusion, Unicode paths, release and fail-closed checks passed.\n";
  return result;
}
