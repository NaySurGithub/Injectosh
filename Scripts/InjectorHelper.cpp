#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>

#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <string>
#include <string_view>

namespace {
constexpr wchar_t game_name[] = L"Minecraft.Windows.exe";

struct Handle {
    HANDLE value = nullptr;
    ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
};

DWORD find_game() {
    Handle snapshot{CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)};
    if (snapshot.value == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32W entry{sizeof(entry)};
    for (BOOL ok = Process32FirstW(snapshot.value, &entry); ok; ok = Process32NextW(snapshot.value, &entry)) {
        if (_wcsicmp(entry.szExeFile, game_name) == 0) return entry.th32ProcessID;
    }
    return 0;
}

std::uintptr_t module_base(DWORD pid, const wchar_t* wanted) {
    Handle snapshot{CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid)};
    if (snapshot.value == INVALID_HANDLE_VALUE) return 0;
    MODULEENTRY32W entry{sizeof(entry)};
    for (BOOL ok = Module32FirstW(snapshot.value, &entry); ok; ok = Module32NextW(snapshot.value, &entry)) {
        if (_wcsicmp(entry.szModule, wanted) == 0) return reinterpret_cast<std::uintptr_t>(entry.modBaseAddr);
    }
    return 0;
}

std::uintptr_t remote_function(DWORD pid, const char* name) {
    const auto kernel = GetModuleHandleW(L"kernel32.dll");
    const auto function = kernel ? GetProcAddress(kernel, name) : nullptr;
    HMODULE provider = nullptr;
    wchar_t provider_path[MAX_PATH]{};
    if (!function ||
        !GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            reinterpret_cast<LPCWSTR>(function), &provider) ||
        !GetModuleFileNameW(provider, provider_path, MAX_PATH)) return 0;
    const std::wstring provider_name = std::filesystem::path(provider_path).filename().wstring();
    const auto remote_provider = module_base(pid, provider_name.c_str());
    if (!remote_provider) return 0;
    return remote_provider + (reinterpret_cast<std::uintptr_t>(function) -
                              reinterpret_cast<std::uintptr_t>(provider));
}

int fail(const char* message, DWORD error = 0) {
    if (error) std::printf("fail %s (Windows error %lu)\n", message, error);
    else std::printf("fail %s\n", message);
    return 1;
}

int inject(const std::filesystem::path& dll) {
    if (!std::filesystem::is_regular_file(dll)) return fail("DLL file not found");
    const DWORD pid = find_game();
    if (!pid) return fail("Minecraft.Windows.exe is not running in this Wine prefix");

    Handle process{OpenProcess(PROCESS_CREATE_THREAD | PROCESS_QUERY_INFORMATION | PROCESS_VM_OPERATION |
                                   PROCESS_VM_WRITE | PROCESS_VM_READ,
                               FALSE, pid)};
    if (!process.value) return fail("could not open Minecraft", GetLastError());

    const auto load_address = remote_function(pid, "LoadLibraryW");
    if (!load_address) return fail("could not resolve LoadLibraryW in Minecraft");

    const std::wstring path = dll.wstring();
    const SIZE_T bytes = (path.size() + 1) * sizeof(wchar_t);
    void* remote_path = VirtualAllocEx(process.value, nullptr, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remote_path) return fail("could not allocate remote path", GetLastError());
    SIZE_T written = 0;
    if (!WriteProcessMemory(process.value, remote_path, path.c_str(), bytes, &written) || written != bytes) {
        const DWORD error = GetLastError();
        VirtualFreeEx(process.value, remote_path, 0, MEM_RELEASE);
        return fail("could not write DLL path into Minecraft", error);
    }
    Handle thread{CreateRemoteThread(process.value, nullptr, 0,
        reinterpret_cast<LPTHREAD_START_ROUTINE>(load_address), remote_path, 0, nullptr)};
    if (!thread.value) {
        const DWORD error = GetLastError();
        VirtualFreeEx(process.value, remote_path, 0, MEM_RELEASE);
        return fail("could not start the DLL loader thread", error);
    }
    const DWORD wait = WaitForSingleObject(thread.value, 30000);
    DWORD loaded = 0;
    const BOOL got_result = wait == WAIT_OBJECT_0 && GetExitCodeThread(thread.value, &loaded);
    VirtualFreeEx(process.value, remote_path, 0, MEM_RELEASE);
    if (wait != WAIT_OBJECT_0) return fail("DLL loader did not finish within 30 seconds");
    if (!got_result || loaded == 0) return fail("LoadLibraryW could not load the DLL", GetLastError());
    std::printf("ok DLL loaded into Minecraft (PID %lu)\n", pid);
    return 0;
}

int uninject(const std::filesystem::path& dll) {
    const DWORD pid = find_game();
    if (!pid) return fail("Minecraft.Windows.exe is not running in this Wine prefix");
    const auto module = module_base(pid, dll.filename().c_str());
    if (!module) return fail("DLL is not loaded in Minecraft");
    Handle process{OpenProcess(PROCESS_CREATE_THREAD | PROCESS_QUERY_INFORMATION | PROCESS_VM_OPERATION |
                                   PROCESS_VM_READ,
                               FALSE, pid)};
    if (!process.value) return fail("could not open Minecraft", GetLastError());
    const auto free_library = remote_function(pid, "FreeLibrary");
    if (!free_library) return fail("could not resolve FreeLibrary in Minecraft");
    Handle thread{CreateRemoteThread(process.value, nullptr, 0,
        reinterpret_cast<LPTHREAD_START_ROUTINE>(free_library), reinterpret_cast<void*>(module), 0, nullptr)};
    if (!thread.value) return fail("could not start the DLL unload thread", GetLastError());
    if (WaitForSingleObject(thread.value, 30000) != WAIT_OBJECT_0) return fail("DLL unload did not finish within 30 seconds");
    if (module_base(pid, dll.filename().c_str())) return fail("DLL remains loaded; another component may hold a reference");
    std::printf("ok DLL unloaded from Minecraft (PID %lu)\n", pid);
    return 0;
}

int report_status(const std::filesystem::path& dll) {
    const DWORD pid = find_game();
    if (!pid) return fail("Minecraft.Windows.exe is not running in this Wine prefix");
    const bool loaded = module_base(pid, dll.filename().c_str()) != 0;
    std::printf("ok %s\n", loaded ? "loaded" : "not-loaded");
    return 0;
}
}

int wmain(int argc, wchar_t** argv) {
    if (argc != 3) {
        std::puts("fail usage: InjectoshInjector inject|uninject|status <dll-path>");
        return 2;
    }
    const std::filesystem::path dll(argv[2]);
    if (_wcsicmp(argv[1], L"inject") == 0) return inject(dll);
    if (_wcsicmp(argv[1], L"uninject") == 0) return uninject(dll);
    if (_wcsicmp(argv[1], L"status") == 0) return report_status(dll);
    return fail("unknown command");
}
