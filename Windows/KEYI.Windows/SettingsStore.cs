using System.IO;
using KEYI.Core;

namespace KEYI.Windows;

internal sealed class SettingsStore
{
    private readonly string _directory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "KEYI");

    private readonly string _legacyDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "HanYi");

    public string FilePath => Path.Combine(_directory, "settings.json");

    private string LegacyFilePath => Path.Combine(_legacyDirectory, "settings.json");

    public AppSettings Load() => SettingsFileStore.Load(FilePath, LegacyFilePath);

    public void Save(AppSettings settings) => SettingsFileStore.Save(FilePath, settings);
}
