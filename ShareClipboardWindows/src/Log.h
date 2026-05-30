#pragma once

#include <string>

namespace sc {

void Log(const std::string& message);
void Logf(const char* format, ...);

}  // namespace sc
