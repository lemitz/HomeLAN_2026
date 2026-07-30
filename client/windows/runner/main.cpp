#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <dwmapi.h>
#include <timeapi.h>

#include "flutter_window.h"
#include "utils.h"

#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "winmm.lib")

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  
  // Повышаем точность таймера до 1мс (важно для высокого FPS)
  timeBeginPeriod(1);
  
  // Запрашиваем высокую производительность GPU (для ноутбуков)
  SetEnvironmentVariable(L"DISABLE_LAYER_AMD_SWITCHABLE_GRAPHICS_1", L"1");
  
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
    timeEndPeriod(1);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // Настраиваем окно для высокого FPS
  HWND hwnd = window.GetHandle();
  if (hwnd) {
    // Отключаем системные анимации для окна
    BOOL disable_transitions = TRUE;
    DwmSetWindowAttribute(hwnd, DWMWA_TRANSITIONS_FORCEDISABLED, 
                          &disable_transitions, sizeof(disable_transitions));
    
    // Включаем Redirection Bitmap (может помочь с ресайзом)
    BOOL use_redirection = FALSE;
    DwmSetWindowAttribute(hwnd, DWMWA_ALLOW_NCPAINT, 
                          &use_redirection, sizeof(use_redirection));
  }

  // Message loop
  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  timeEndPeriod(1);
  ::CoUninitialize();
  return EXIT_SUCCESS;
}