#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shlobj.h>

#include <filesystem>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "profile_lock.h"
#include "utils.h"

namespace {
std::wstring EnvironmentValue(const wchar_t* name) {
  const DWORD size = ::GetEnvironmentVariableW(name, nullptr, 0);
  if (size == 0) return {};
  std::vector<wchar_t> buffer(size);
  const DWORD copied = ::GetEnvironmentVariableW(name, buffer.data(), size);
  return copied > 0 && copied < size ? std::wstring(buffer.data(), copied) : L"";
}

bool ProfileDirectory(std::filesystem::path* result) {
  const auto override_path = EnvironmentValue(L"CAKE_WALLET_DIR");
  if (!override_path.empty()) {
    *result = override_path;
    return true;
  }
  PWSTR roaming = nullptr;
  const HRESULT status = ::SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0,
                                               nullptr, &roaming);
  if (FAILED(status)) return false;
  // Match the stable CompanyName/ProductName used by path_provider_windows.
  *result = std::filesystem::path(roaming) / L"vitorhubdev" / L"Cake Wallet Windows";
  ::CoTaskMemFree(roaming);
  return true;
}

struct ComScope {
  ~ComScope() { ::CoUninitialize(); }
};
}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                     _In_ wchar_t* command_line, _In_ int show_command) {
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }
  if (FAILED(::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return EXIT_FAILURE;
  ComScope com;

  std::filesystem::path profile;
  if (!ProfileDirectory(&profile)) {
    ::MessageBoxW(nullptr, L"Unable to locate the Windows wallet data directory.",
                  L"Cake Wallet Windows", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }
  ProfileLock profile_lock;
  const DWORD lock_status = profile_lock.Acquire(profile);
  if (lock_status == ERROR_SHARING_VIOLATION || lock_status == ERROR_LOCK_VIOLATION) {
    // Do not initialize Flutter, SQLite or native wallets a second time.
    const HWND existing = ::FindWindowW(nullptr, L"Cake Wallet Windows");
    if (existing != nullptr) {
      ::ShowWindow(existing, SW_RESTORE);
      ::SetForegroundWindow(existing);
    }
    return EXIT_SUCCESS;
  }
  if (lock_status != ERROR_SUCCESS) {
    const std::wstring message = L"Unable to lock the wallet data directory. Check file permissions and available disk space. Windows error: " +
                                 std::to_wstring(lock_status);
    ::MessageBoxW(nullptr, message.c_str(), L"Cake Wallet Windows", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }

  std::vector<wchar_t> module(32768);
  const DWORD size = ::GetModuleFileNameW(nullptr, module.data(), static_cast<DWORD>(module.size()));
  if (size == 0 || size >= module.size()) return EXIT_FAILURE;
  const auto data = std::filesystem::path(std::wstring(module.data(), size)).parent_path() / L"data";
  flutter::DartProject project(data.wstring());
  project.set_dart_entrypoint_arguments(GetCommandLineArguments());

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size window_size(1280, 720);
  if (!window.Create(L"Cake Wallet Windows", origin, window_size)) return EXIT_FAILURE;
  window.SetQuitOnClose(true);

  MSG msg;
  BOOL result;
  while ((result = ::GetMessage(&msg, nullptr, 0, 0)) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }
  return result < 0 ? EXIT_FAILURE : EXIT_SUCCESS;
}
