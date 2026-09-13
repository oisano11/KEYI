using System.IO;
using KEYI.Core;

namespace KEYI.Windows;

internal sealed class SettingsStore
{
    private readonly string _directory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "KEYI");

    public string FilePath => Path.Combine(_directory, "settings.json");

    public AppSettings Load() => SettingsFileStore.Load(FilePath);

    public void Save(AppSettings settings) => SettingsFileStore.Save(FilePath, settings);
}
