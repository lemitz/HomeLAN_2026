#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <dwmapi.h>
#include <timeapi.h>

#include "flutter_window.h"
#include "utils.h"

#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "winmm.lib")

// Ноутбуки с двумя видеокартами: просим дискретную (NVIDIA Optimus / AMD).
extern "C" {
__declspec(dllexport) DWORD NvOptimusEnablement = 0x00000001;
__declspec(dllexport) int AmdPowerXpressRequestHighPerformance = 1;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Один экземпляр: два клиента с одним device_id мешали бы друг другу
  // (общий WebSocket и локальная БД). Имя мьютекса использует и инсталлятор.
  HANDLE mutex = ::CreateMutexW(nullptr, TRUE, L"HomeLANClientMutex");
  if (mutex && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = ::FindWindowW(nullptr, L"HomeLAN Messenger");
    if (existing) {
      ::ShowWindow(existing, SW_RESTORE);
      ::SetForegroundWindow(existing);
    }
    ::CloseHandle(mutex);
    return EXIT_SUCCESS;
  }

  // Точность системного таймера 1 мс: без неё планировщик кадров движка
  // просыпается с шагом ~15,6 мс и на 120/144 Гц кадры идут неровно.
  // С Windows 10 2004 настройка действует только на этот процесс.
  ::timeBeginPeriod(1);

  // Windows 11 может включать «эко-режим» (EcoQoS) для фоновых окон —
  // это даёт рывки при возврате к окну. Отключаем троттлинг для процесса.
  PROCESS_POWER_THROTTLING_STATE throttling{};
  throttling.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
  throttling.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
  throttling.StateMask = 0;
  ::SetProcessInformation(::GetCurrentProcess(), ProcessPowerThrottling, &throttling, sizeof(throttling));

  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"HomeLAN Messenger", origin, size)) {
    if (mutex) ::CloseHandle(mutex);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  HWND hwnd = window.GetHandle();
  if (hwnd) {
    // Отключаем анимации окна DWM.
    BOOL disable_transitions = TRUE;
    DwmSetWindowAttribute(hwnd, DWMWA_TRANSITIONS_FORCEDISABLED,
                          &disable_transitions, sizeof(disable_transitions));
    // Не показывать окно в скриншотах и записи экрана (аналог FLAG_SECURE).
    ::SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ::timeEndPeriod(1);
  if (mutex) ::CloseHandle(mutex);
  return EXIT_SUCCESS;
}
