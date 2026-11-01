#include "my_application.h"
#include "profile_lock.h"

#include <cstdio>
#include <string>

int main(int argc, char** argv) {
  const char* override_path = g_getenv("CAKE_WALLET_DIR");
  std::filesystem::path profile;
  if (override_path != nullptr && *override_path != '\0') {
    profile = override_path;
  } else {
    const char* xdg = g_getenv("XDG_CONFIG_HOME");
    const char* home = g_getenv("HOME");
    if (xdg != nullptr && *xdg == '/') {
      profile = std::filesystem::path(xdg) / "cake_wallet_pc";
    } else if (home != nullptr && *home == '/') {
      profile = std::filesystem::path(home) / ".config" / "cake_wallet_pc";
    } else {
      std::fputs("Cake Wallet PC requires an absolute HOME or XDG_CONFIG_HOME.\n", stderr);
      return 1;
    }
  }
  ProfileLock lock;
  const int status = lock.Acquire(profile);
  if (status == EWOULDBLOCK || status == EAGAIN) {
    std::fputs("Cake Wallet PC already has this wallet profile open.\n", stderr);
    return 0;
  }
  if (status != 0) {
    std::fprintf(stderr, "Cake Wallet PC cannot lock its data directory (error %d).\n", status);
    return 1;
  }
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
