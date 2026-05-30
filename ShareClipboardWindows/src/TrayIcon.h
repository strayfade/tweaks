#pragma once

#include <Windows.h>

namespace sc {

HICON LoadTrayIcon(HINSTANCE instance);
void DestroyTrayIcon(HICON icon);

}  // namespace sc
