using System.Reflection;
using KEYI.Core;
using KEYI.Windows;

internal static class Program
{
    private static int _checks;

    [STAThread]
    private static void Main()
    {
        foreach (var language in new[] { InterfaceLanguage.English, InterfaceLanguage.SimplifiedChinese })
        {
            var host = new SettingsHost(language);
            // Construct the real form without displaying it or saving credentials.
            using var form = new SettingsForm(host, null);
            var list = Field<ListBox>(form, "_providerList");
            var endpoint = Field<TextBox>(form, "_endpoint");
            var model = Field<TextBox>(form, "_model");
            foreach (var provider in ProviderCatalog.All)
            {
                list.SelectedItem = provider.Id;
                for (var refresh = 0; refresh < 2; refresh++)
                {
                    typeof(SettingsForm).GetMethod("RefreshProviderList",
                        BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(form, null);
                    Assert(list.Items.Cast<object>().All(item => item is ProviderId),
                        "provider list must contain IDs after refresh");
                    Assert(list.Items.Count == ProviderCatalog.All.Count,
                        "refresh must preserve all providers without duplicates");
                    Assert(list.SelectedItem is ProviderId selected && selected == provider.Id,
                        "refresh must preserve the provider being edited");
                    Assert(endpoint.Text == host.Settings.Providers[provider.Id].Endpoint
                        && model.Text == host.Settings.Providers[provider.Id].Model,
                        "selection handlers must load the chosen provider after refresh");
                }
            }
            Assert(host.Settings.SelectedProvider == ProviderId.DeepSeek,
                "editing service settings must not activate a different provider");
        }
        Console.WriteLine($"KEYI Windows form checks passed: {_checks}");
    }

    private static T Field<T>(SettingsForm form, string name) =>
        (T)typeof(SettingsForm).GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(form)!;

    private static void Assert(bool condition, string message)
    {
        _checks++;
        if (!condition) throw new InvalidOperationException(message);
    }

    private sealed class SettingsHost : ISettingsDialogHost
    {
        public SettingsHost(InterfaceLanguage language)
        {
            Settings.EnsureDefaults();
            Strings = UiStrings.For(language);
        }

        public AppSettings Settings { get; } = new();
        public UiStrings Strings { get; }
        public CredentialStore Credentials { get; } = new();
        public bool Persist() => throw new InvalidOperationException("Unexpected settings write");
        public void ApplyHotKey(HotKeySettings settings) => throw new InvalidOperationException("Unexpected hotkey change");
        public void SelectProviderFromSettings(ProviderId provider) => throw new InvalidOperationException("Unexpected provider activation");
        public void ChangeInterfaceLanguage(InterfaceLanguage language) => throw new InvalidOperationException("Unexpected language change");
    }
}
