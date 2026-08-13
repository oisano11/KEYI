using System.Text;
using System.IO;
using HanYi.Core;

namespace HanYi.Windows;

internal sealed class SettingsStore
{
    private readonly string _directory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "HanYi");

    public string FilePath => Path.Combine(_directory, "settings.json");

    public AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                return SettingsJson.Deserialize(File.ReadAllText(FilePath, Encoding.UTF8));
            }
        }
        catch
        {
            // A corrupt preference file must not prevent the tray entry from starting.
        }

        var settings = new AppSettings();
        settings.EnsureDefaults();
        return settings;
    }

    public void Save(AppSettings settings)
    {
        settings.EnsureDefaults();
        Directory.CreateDirectory(_directory);
        var temporaryPath = FilePath + ".tmp";
        File.WriteAllText(temporaryPath, SettingsJson.Serialize(settings), Encoding.UTF8);
        File.Move(temporaryPath, FilePath, true);
    }
}
