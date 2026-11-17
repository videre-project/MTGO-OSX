/* Observe real MTGO startup and page-memory behavior through Win32 APIs.
 * Installation consent is restricted to the official deployment prompt.
 * No input is sent to the game's EULA or login screen.
 */
#define _WIN32_WINNT 0x0601
#include <windows.h>
#include <shellapi.h>
#include <tlhelp32.h>

#if defined(__aarch64__)
#define EXPECTED_MACHINE IMAGE_FILE_MACHINE_ARM64
#define ARCHITECTURE "ARM64"
#elif defined(__x86_64__)
#define EXPECTED_MACHINE IMAGE_FILE_MACHINE_AMD64
#define ARCHITECTURE "x86_64"
#else
#error Unsupported runtime architecture
#endif

static HWND game_window;
static DWORD game_pid;

static void message(const char *text)
{
    DWORD written;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text, lstrlenA(text), &written, NULL);
}

static BOOL check_page_recommit(void)
{
    static const struct { DWORD offset, size; } ranges[] = {
        {0, 4096}, {4096, 4096}, {8192, 4096}, {12288, 4096},
        {4096, 8192}, {4096, 40960}, {0, 16384}, {0, 65536},
    };
    static const DWORD protections[] = {PAGE_READWRITE, PAGE_READONLY, PAGE_NOACCESS};
    DWORD range, protection, offset, previous;
    char output[256];

    for (protection = 0; protection < ARRAYSIZE(protections); ++protection)
        for (range = 0; range < ARRAYSIZE(ranges); ++range)
        {
            BYTE *memory = VirtualAlloc(NULL, 65536, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
            BYTE *part;
            MEMORY_BASIC_INFORMATION info;
            BOOL valid = FALSE;
            if (!memory) { message("FAIL: Could not allocate the memory test region.\n"); return FALSE; }
            part = memory + ranges[range].offset;
            for (offset = 0; offset < 65536; ++offset) memory[offset] = 0x80 + offset / 4096;

            /* Decommit a Windows page while adjacent pages may share its host page. */
            if (!VirtualProtect(memory, 65536, protections[protection], &previous)
                || !VirtualFree(part, ranges[range].size, MEM_DECOMMIT)
                || VirtualAlloc(part, ranges[range].size, MEM_COMMIT, PAGE_READWRITE) != part)
            {
                message("FAIL: Could not decommit and recommit Windows pages.\n");
                goto done;
            }
            for (offset = 0; offset < 65536; offset += 4096)
            {
                DWORD expected = offset >= ranges[range].offset && offset < ranges[range].offset + ranges[range].size
                    ? PAGE_READWRITE : protections[protection];
                if (!VirtualQuery(memory + offset, &info, sizeof(info))
                    || info.State != MEM_COMMIT || info.Protect != expected)
                {
                    message("FAIL: Recommitting memory changed adjacent page protections.\n");
                    goto done;
                }
            }
            if (!VirtualProtect(memory, 65536, PAGE_READWRITE, &previous)) goto done;

            /* A zeroing fix must preserve every live byte outside the decommitted range. */
            for (offset = 0; offset < 65536; ++offset)
            {
                BYTE expected = offset >= ranges[range].offset && offset < ranges[range].offset + ranges[range].size
                    ? 0 : 0x80 + offset / 4096;
                if (memory[offset] != expected)
                {
                    wsprintfA(output, "FAIL: range %lu+%lu, protection %#lx, byte %lu: got %u, expected %u.\n",
                              ranges[range].offset, ranges[range].size, protections[protection],
                              offset, memory[offset], expected);
                    message(output);
                    goto done;
                }
            }
            valid = TRUE;
        done:
            VirtualFree(memory, 0, MEM_RELEASE);
            if (!valid) return FALSE;
        }
    message("PASS: Recommitted Windows pages are zeroed; adjacent data and protections are preserved.\n");
    return TRUE;
}

struct install_prompt { BOOL product, domain; HWND button; };

static BOOL CALLBACK inspect_prompt(HWND window, LPARAM parameter)
{
    struct install_prompt *prompt = (void *)parameter;
    WCHAR text[512];
    GetWindowTextW(window, text, ARRAYSIZE(text));
    if (!lstrcmpW(text, L"Magic The Gathering Online ")) prompt->product = TRUE;
    if (!lstrcmpW(text, L"mtgo.patch.daybreakgames.com")) prompt->domain = TRUE;
    if (!lstrcmpW(text, L"&Install")) prompt->button = window;
    return TRUE;
}

static BOOL is_game_process(DWORD pid)
{
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    WCHAR path[MAX_PATH], *name = path;
    DWORD length = ARRAYSIZE(path);
    BOOL result = FALSE;
    if (!process) return FALSE;
    if (QueryFullProcessImageNameW(process, 0, path, &length))
    {
        for (WCHAR *cursor = path; *cursor; ++cursor)
            if (*cursor == L'\\' || *cursor == L'/') name = cursor + 1;
        result = !lstrcmpiW(name, L"MTGO.exe");
    }
    CloseHandle(process);
    return result;
}

static BOOL CALLBACK inspect_window(HWND window, LPARAM parameter)
{
    WCHAR title[256];
    DWORD pid;
    (void)parameter;
    if (!IsWindowVisible(window)) return TRUE;
    GetWindowTextW(window, title, ARRAYSIZE(title));
    if (!lstrcmpW(title, L"Application Install - Security Warning"))
    {
        struct install_prompt prompt;
        prompt.product = prompt.domain = FALSE;
        prompt.button = NULL;
        EnumChildWindows(window, inspect_prompt, (LPARAM)&prompt);
        if (prompt.product && prompt.domain && prompt.button)
        {
            message("Confirming the official MTGO installation prompt.\n");
            PostMessageW(prompt.button, BM_CLICK, 0, 0);
        }
    }
    if (!lstrcmpW(title, L"Magic: The Gathering Online"))
    {
        GetWindowThreadProcessId(window, &pid);
        if (is_game_process(pid)) { game_window = window; game_pid = pid; }
    }
    return TRUE;
}

static BOOL native_module(HANDLE process, const MODULEENTRY32W *module)
{
    IMAGE_DOS_HEADER dos;
    struct { DWORD signature; WORD machine; } pe;
    SIZE_T count;
    if (!ReadProcessMemory(process, module->modBaseAddr, &dos, sizeof(dos), &count)
        || count != sizeof(dos) || dos.e_magic != IMAGE_DOS_SIGNATURE
        || module->modBaseSize < 6 || dos.e_lfanew < 0
        || (DWORD)dos.e_lfanew > module->modBaseSize - 6) return FALSE;
    return ReadProcessMemory(process, module->modBaseAddr + dos.e_lfanew, &pe, 6, &count)
        && count == 6 && pe.signature == IMAGE_NT_SIGNATURE && pe.machine == EXPECTED_MACHINE;
}

static BOOL has_native_clr(DWORD pid)
{
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, pid);
    HANDLE process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, pid);
    MODULEENTRY32W module;
    BOOL clr = FALSE, jit = FALSE;
    module.dwSize = sizeof(module);
    if (process && snapshot != INVALID_HANDLE_VALUE && Module32FirstW(snapshot, &module))
    {
        do
        {
            if (!lstrcmpiW(module.szModule, L"clr.dll")) clr = native_module(process, &module);
            if (!lstrcmpiW(module.szModule, L"clrjit.dll")) jit = native_module(process, &module);
        } while (Module32NextW(snapshot, &module));
    }
    if (process) CloseHandle(process);
    if (snapshot != INVALID_HANDLE_VALUE) CloseHandle(snapshot);
    return clr && jit;
}

static BOOL CALLBACK print_window(HWND window, LPARAM parameter)
{
    WCHAR title[256];
    char utf8[1024];
    DWORD written;
    int length;
    (void)parameter;
    if (!IsWindowVisible(window)) return TRUE;
    length = GetWindowTextW(window, title, ARRAYSIZE(title));
    length = WideCharToMultiByte(CP_UTF8, 0, title, length, utf8, sizeof(utf8), NULL, NULL);
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), utf8, length, &written, NULL);
    message("\n");
    return TRUE;
}

void mainCRTStartup(void)
{
    int argc;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    DWORD timeout = 0;
    ULONGLONG deadline, stable_since = 0;
    HWND stable_window = NULL;
    DWORD stable_pid = 0;
    if (argv && argc == 2 && !lstrcmpW(argv[1], L"--memory"))
        ExitProcess(check_page_recommit() ? 0 : 1);
    if (argv && argc == 2)
        for (WCHAR *cursor = argv[1]; *cursor && timeout <= 3600; ++cursor)
        {
            if (*cursor < L'0' || *cursor > L'9') { timeout = 0; break; }
            timeout = timeout * 10 + *cursor - L'0';
        }
    if (!timeout || timeout > 3600)
    {
        message("Usage: mtgo-startup.exe TIMEOUT_SECONDS (1..3600) or --memory\n");
        ExitProcess(2);
    }
    deadline = GetTickCount64() + (ULONGLONG)timeout * 1000;
    message("Waiting for the real MTGO main window and " ARCHITECTURE " CLR/JIT...\n");
    while (GetTickCount64() < deadline)
    {
        game_window = NULL;
        EnumWindows(inspect_window, 0);
        if (game_window && has_native_clr(game_pid))
        {
            if (stable_window != game_window || stable_pid != game_pid)
            {
                stable_window = game_window;
                stable_pid = game_pid;
                stable_since = GetTickCount64();
            }
            if (GetTickCount64() - stable_since >= 10000)
            {
                message("PASS: MTGO opened its main window and remained running for 10 seconds with the " ARCHITECTURE " CLR and JIT.\n");
                ExitProcess(0);
            }
        }
        else { stable_window = NULL; stable_since = 0; }
        Sleep(500);
    }
    message("FAIL: MTGO did not reach stable " ARCHITECTURE " startup before the timeout. Visible windows:\n");
    EnumWindows(print_window, 0);
    ExitProcess(1);
}
