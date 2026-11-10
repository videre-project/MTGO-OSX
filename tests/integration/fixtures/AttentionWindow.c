/* Exercise the real Wine attention hook from the window's own process. */
#define _WIN32_WINNT 0x0601
#include <windows.h>
#include <shellapi.h>

static const WCHAR title[] = L"MTGO Dock attention test";
static const WCHAR *commands;

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{
    if (message == WM_TIMER)
    {
        HANDLE file = CreateFileW(commands, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                  NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        char request[2], command;
        DWORD count;
        if (file == INVALID_HANDLE_VALUE) return 0;
        if (!ReadFile(file, request, sizeof(request), &count, NULL)) count = 0;
        CloseHandle(file);
        if (count != 1) return 0;
        command = request[0];

        {
            char line[128];
            int length = wsprintfA(line, "Command %c: foreground=%p window=%p\n", command,
                                   GetForegroundWindow(), window);
            WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), line, length, &count, NULL);
        }

        if (command == 'q') DestroyWindow(window);
        else
        {
            FLASHWINFO info = {sizeof(info), window, FLASHW_STOP, 0, 0};
            if (command == 'a') info.dwFlags = FLASHW_ALL | FLASHW_TIMERNOFG;
            else if (command == 'c') info.dwFlags = FLASHW_CAPTION;
            FlashWindowEx(&info);
        }

        /* The native assertions must wait until this process has handled the command. */
        file = CreateFileW(commands, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        if (file != INVALID_HANDLE_VALUE)
        {
            WriteFile(file, "!", 1, &count, NULL);
            CloseHandle(file);
        }
        return 0;
    }
    if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(window, message, wparam, lparam);
}

void mainCRTStartup(void)
{
    int argc;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    WNDCLASSW type = {0};
    MSG message;
    HWND window;
    if (!argv || argc != 2) ExitProcess(2);
    commands = argv[1];

    /* Match the game's main-window reporting without loading MTGO or Framework. */
    if (RegSetKeyValueW(HKEY_CURRENT_USER, L"Software\\Wine\\AppDefaults\\MTGO.exe\\Mac Driver",
                       L"MainWindowTitle", REG_SZ, title, sizeof(title))) ExitProcess(5);
    if (!lstrcmpW(argv[1], L"--configure")) ExitProcess(0);
    type.lpfnWndProc = window_proc;
    type.hInstance = GetModuleHandleW(NULL);
    type.lpszClassName = L"MTGODockAttentionTest";
    if (!RegisterClassW(&type)) ExitProcess(3);
    window = CreateWindowW(type.lpszClassName, title, WS_OVERLAPPEDWINDOW,
                           CW_USEDEFAULT, CW_USEDEFAULT, 320, 160, NULL, NULL, type.hInstance, NULL);
    if (!window) ExitProcess(4);
    ShowWindow(window, SW_SHOWNOACTIVATE);
    SetTimer(window, 1, 50, NULL);

    while (GetMessageW(&message, NULL, 0, 0) > 0)
    {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    ExitProcess(0);
}
