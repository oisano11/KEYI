using System.Text;

namespace KEYI.Core;

public static class SettingsFileStore
{
    public static AppSettings Load(string currentPath)
    {
        if (TryLoad(currentPath, out var currentSettings))
        {
            return currentSettings;
        }

        return DefaultSettings();
    }

    public static void Save(string path, AppSettings settings)
    {
        settings.EnsureDefaults();
        var directory = Path.GetDirectoryName(path)
            ?? throw new InvalidOperationException("Settings path has no directory");
        Directory.CreateDirectory(directory);
        var temporaryPath = path + ".tmp";
        File.WriteAllText(temporaryPath, SettingsJson.Serialize(settings), Encoding.UTF8);
        File.Move(temporaryPath, path, true);
    }

    private static bool TryLoad(string path, out AppSettings settings)
    {
        try
        {
            if (File.Exists(path))
            {
                settings = SettingsJson.Deserialize(File.ReadAllText(path, Encoding.UTF8));
                return true;
            }
        }
        catch
        {
            // A corrupt preference file must not prevent the tray entry from starting.
        }

        settings = DefaultSettings();
        return false;
    }

    private static AppSettings DefaultSettings()
    {
        var settings = new AppSettings();
        settings.EnsureDefaults();
        return settings;
    }
}
