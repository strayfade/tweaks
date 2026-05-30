using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ScreenMirroringViewer.Services;

public sealed class AppSettings
{
    private static readonly string SettingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ScreenMirroringViewer",
        "settings.json");

    public string? SavedPassword { get; set; }
    public string? LastKnownHost { get; set; }
    public string? LastKnownDeviceName { get; set; }
    public bool RememberPassword { get; set; } = true;
    public bool AutoRotateLandscape { get; set; } = true;

    public static AppSettings Load()
    {
        try
        {
            if (!File.Exists(SettingsPath))
            {
                return new AppSettings();
            }

            var json = File.ReadAllText(SettingsPath);
            var settings = JsonSerializer.Deserialize<AppSettings>(json) ?? new AppSettings();
            if (!string.IsNullOrEmpty(settings.SavedPassword))
            {
                settings.SavedPassword = Unprotect(settings.SavedPassword);
            }

            return settings;
        }
        catch
        {
            return new AppSettings();
        }
    }

    public void Save()
    {
        var directory = Path.GetDirectoryName(SettingsPath)!;
        Directory.CreateDirectory(directory);

        var copy = new AppSettings
        {
            RememberPassword = RememberPassword,
            AutoRotateLandscape = AutoRotateLandscape,
            LastKnownHost = LastKnownHost,
            LastKnownDeviceName = LastKnownDeviceName,
            SavedPassword = RememberPassword && !string.IsNullOrEmpty(SavedPassword)
                ? Protect(SavedPassword)
                : null,
        };

        var json = JsonSerializer.Serialize(copy, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(SettingsPath, json);
    }

    private static string Protect(string plainText)
    {
        var bytes = Encoding.UTF8.GetBytes(plainText);
        var protectedBytes = ProtectedData.Protect(bytes, null, DataProtectionScope.CurrentUser);
        return Convert.ToBase64String(protectedBytes);
    }

    private static string Unprotect(string protectedText)
    {
        var protectedBytes = Convert.FromBase64String(protectedText);
        var bytes = ProtectedData.Unprotect(protectedBytes, null, DataProtectionScope.CurrentUser);
        return Encoding.UTF8.GetString(bytes);
    }
}
