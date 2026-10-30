import ctypes
import json
import os
import secrets
import subprocess
import sys
import tempfile
from pathlib import Path

def worker(bundle, label, bad_pass):
    step = "load"
    wallet = None
    manager = None
    report = {"path": label, "wrong_password": bad_pass, "ok": False}
    try:
        os.environ["PATH"] = str(bundle) + os.pathsep + os.environ.get("PATH", "")
        dll_search = os.add_dll_directory(str(bundle))
        lib = ctypes.CDLL(str(bundle / "libmonero_wallet2_api_c.dll"))
        def api(name, ret, *types):
            fn = getattr(lib, "MONERO_" + name)
            fn.restype, fn.argtypes = ret, list(types)
            return fn
        ptr, s, i, flag = ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_bool
        get_manager = api("WalletManagerFactory_getWalletManager", ptr)
        set_log = api("WalletManagerFactory_setLogLevel", None, i)
        create = api("WalletManager_createWallet", ptr, ptr, s, s, s, i)
        reopen = api("WalletManager_openWallet", ptr, ptr, s, s, i)
        close = api("WalletManager_closeWallet", flag, ptr, ptr, flag)
        status = api("Wallet_status", i, ptr)
        store = api("Wallet_store", flag, ptr, s)
        address = api("Wallet_address", ptr, ptr, i, i)
        seed = api("Wallet_seed", ptr, ptr, s)
        free = api("free", None, ptr)
        offline = api("Wallet_setOffline", None, ptr, flag)
        is_offline = api("Wallet_isOffline", flag, ptr)

        def read_string(fn, *args):
            result = fn(*args)
            if not result:
                raise RuntimeError("native string returned null")
            try:
                return ctypes.string_at(result).decode("utf-8")
            finally:
                free(result)

        def identity(w):
            code = status(w)
            if code:
                raise RuntimeError("native wallet status nonzero")
            offline(w, True)
            if not is_offline(w):
                raise RuntimeError("native offline check failed")
            return read_string(address, w, 0, 0), read_string(seed, w, b"")

        set_log(-1)
        manager = get_manager()
        if not manager:
            raise RuntimeError("wallet manager returned null")
        with tempfile.TemporaryDirectory(prefix="cake-smoke-") as temp:
            directory = Path(temp) / ("wallet data espaço" if label == "unicode" else "wallet data")
            directory.mkdir()
            wallet_path = str(directory / "offline_testnet")
            path = wallet_path.encode("utf-8")
            password = secrets.token_urlsafe(32).encode("ascii")
            step = "create"
            wallet = create(manager, path, password, b"English", 1)
            if not wallet:
                raise RuntimeError("create returned null")
            first_address, first_seed = identity(wallet)
            report["seed_words"] = len(first_seed.split())
            step = "store_close"
            if not store(wallet, b""):
                raise RuntimeError("store false")
            original, wallet = wallet, None
            if not close(manager, original, False):
                raise RuntimeError("close false")
            if not os.path.exists(wallet_path) or not os.path.exists(wallet_path + ".keys"):
                raise RuntimeError("cache or keys missing")
            if bad_pass:
                step = "reject_wrong_password"
                wallet = reopen(manager, path, password + b"-incorrect", 1)
                if wallet:
                    report["wrong_password_rejected"] = status(wallet) != 0
                    if not report["wrong_password_rejected"]:
                        raise RuntimeError("invalid password accepted")
                    original, wallet = wallet, None
                    report["wrong_password_close_ok"] = bool(close(manager, original, False))
            step = "reopen_identity"
            wallet = reopen(manager, path, password, 1)
            if not wallet:
                raise RuntimeError("reopen returned null")
            second_address, second_seed = identity(wallet)
            report["address_equal"] = (first_address == second_address)
            report["seed_equal"] = (first_seed == second_seed)
            report["seed_equal_normalized"] = (" ".join(first_seed.split()) == " ".join(second_seed.split()))
            report["reopen_words"] = len(second_seed.split())
            original, wallet = wallet, None
            report["close_ok"] = bool(close(manager, original, False))
            report["ok"] = report["address_equal"] and report["seed_equal_normalized"] and report["close_ok"]
    except BaseException as error:
        report["step"] = step
        report["error_type"] = type(error).__name__
    finally:
        if wallet and manager:
            try:
                close(manager, wallet, False)
            except BaseException:
                pass
    print("CAKE_DIAG " + json.dumps(report, sort_keys=True), flush=True)

def main():
    if len(sys.argv) == 5 and sys.argv[1] == "--worker":
        worker(Path(sys.argv[2]).resolve(), sys.argv[3], sys.argv[4] == "yes")
        return
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python diagnose_monero_ctypes.py <bundle path>")
    bundle = Path(sys.argv[1]).resolve()
    if not (bundle / "libmonero_wallet2_api_c.dll").exists():
        raise SystemExit("Native DLL is missing")
    results = []
    for label in ("ascii", "unicode"):
        for wrong_pass in ("no", "yes"):
            command = [sys.executable, __file__, "--worker", str(bundle), label, wrong_pass]
            try:
                process = subprocess.run(command, text=True, capture_output=True, timeout=75)
                rows = [line[len("CAKE_DIAG "):] for line in process.stdout.splitlines() if line.startswith("CAKE_DIAG ")]
                report = json.loads(rows[-1]) if len(rows) == 1 else {"path": label, "wrong_password":wrong_pass, "ok": False, "error_type":"worker_failed"}
                report["worker_exit_ok"] = process.returncode == 0
            except subprocess.TimeoutExpired:
                report = {"path": label, "wrong_password":wrong_pass, "ok": False, "error_type": "timeout"}
            results.append(report)
            print(json.dumps(report, sort_keys=True), flush=True)
    Path("monero-diagnostic.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    # Observational diagnostic; interpret the result before changing release gates.

if __name__ == "__main__":
    main()
