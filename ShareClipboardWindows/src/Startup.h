#pragma once

namespace sc {

constexpr wchar_t kStartupRegistryName[] = L"ShareClipboard";

bool IsRunOnBootEnabled();
void SetRunOnBoot(bool enabled);
void EnsureDefaultRunOnBoot();

}  // namespace sc
