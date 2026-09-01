using KEYI.Core;

namespace KEYI.Windows;

/// 设置窗口宿主回调：变更持久化与既有应用流程（热键、提供方切换）
/// 全部复用 AppController 的实现，避免第二套保存/回滚逻辑。
internal interface ISettingsDialogHost
{
    AppSettings Settings { get; }

    UiStrings Strings { get; }

    CredentialStore Credentials { get; }

    bool Persist();

    void ApplyHotKey(HotKeySettings settings);

    void SelectProviderFromSettings(ProviderId provider);

    void ChangeInterfaceLanguage(InterfaceLanguage language);
}

internal sealed class SettingsForm : Form
{
    private readonly ISettingsDialogHost _host;
    private readonly ProviderId? _preselectProvider;

    private readonly TabControl _tabs = new();
    private readonly ComboBox _targetLanguage = new();
    private readonly ComboBox _scene = new();
    private readonly ComboBox _style = new();
    private readonly Label _styleHint = new();
    private readonly ListBox _providerList = new();
    private readonly TextBox _apiKey = new();
    private readonly TextBox _endpoint = new();
    private readonly TextBox _model = new();
    private readonly Button _saveProvider = new();
    private readonly Button _useCurrent = new();
    private readonly Button _changeHotKey = new();
    private readonly Button _restoreHotKey = new();
    private readonly Label _hotKeyValue = new();
    private readonly ComboBox _interfaceLanguage = new();
    private readonly Label _status = new();

    public SettingsForm(ISettingsDialogHost host, ProviderId? preselectProvider)
    {
        _host = host;
        _preselectProvider = preselectProvider;
        var strings = host.Strings;

        Text = strings.SettingsTitle;
        AutoScaleMode = AutoScaleMode.Dpi;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = true;
        ClientSize = new Size(560, 380);

        _tabs.Dock = DockStyle.Fill;

        BuildTranslationTab(strings);
        BuildProvidersTab(strings);
        BuildHotKeyTab(strings);
        BuildGeneralTab(strings);

        _status.Dock = DockStyle.Bottom;
        _status.Height = 32;
        _status.TextAlign = ContentAlignment.MiddleLeft;
        _status.Padding = new Padding(12, 0, 0, 0);

        Controls.Add(_tabs);
        Controls.Add(_status);
    }

    // MARK: 翻译偏好

    private void BuildTranslationTab(UiStrings strings)
    {
        var page = new TabPage(strings.TranslationTab);
        var layout = NewFormLayout();

        AddCombo(layout, strings.TargetLanguage, _targetLanguage,
            Enum.GetValues<TranslationLanguage>(),
            language => strings.LanguageName(language),
            _settings().TargetLanguage,
            value =>
            {
                ApplyPreference(
                    () => _settings().TargetLanguage,
                    value2 => _settings().TargetLanguage = value2,
                    value);
            });
        AddCombo(layout, strings.Scene, _scene,
            Enum.GetValues<TranslationScene>(),
            scene => strings.SceneName(scene),
            _settings().Scene,
            value =>
            {
                ApplyPreference(
                    () => _settings().Scene,
                    value2 => _settings().Scene = value2,
                    value);
                RefreshTranslationTab();
            });
        AddCombo(layout, strings.Style, _style,
            Enum.GetValues<EnglishStyle>(),
            style => strings.StyleName(style),
            _settings().EnglishStyle,
            value =>
            {
                ApplyPreference(
                    () => _settings().EnglishStyle,
                    value2 => _settings().EnglishStyle = value2,
                    value);
            });

        _styleHint.ForeColor = SystemColors.GrayText;
        layout.Controls.Add(_styleHint, 1, layout.RowCount);
        RefreshTranslationTab();

        page.Controls.Add(layout);
        _tabs.TabPages.Add(page);
    }

    private void RefreshTranslationTab()
    {
        var settings = _settings();
        var styleEnabled = TranslationPromptBuilder.UsesEnglishStyle(
            settings.TargetLanguage,
            settings.Scene);
        _style.Enabled = styleEnabled;
        _styleHint.Text = _host.Strings.SceneStyleHint(
            supportsScene: true,
            supportsStyle: styleEnabled,
            scene: settings.Scene);
    }

    // MARK: 提供方

    private void BuildProvidersTab(UiStrings strings)
    {
        var page = new TabPage(strings.ProvidersTab);

        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(12),
            ColumnCount = 2,
            RowCount = 1
        };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 200));
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));

        _providerList.Dock = DockStyle.Fill;
        foreach (var provider in ProviderCatalog.All)
        {
            _providerList.Items.Add(provider.Id);
        }
        _providerList.SelectedIndexChanged += (_, _) =>
        {
            _status.Text = "";
            LoadProviderFields();
        };
        _providerList.Format += (_, args) =>
        {
            if (args.ListItem is ProviderId provider)
            {
                args.Value = ProviderRowLabel(provider);
            }
        };
        root.Controls.Add(_providerList, 0, 0);

        var detail = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            RowCount = 5,
            AutoSize = true
        };
        detail.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 110));
        detail.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));

        _apiKey.UseSystemPasswordChar = true;
        AddDetailRow(detail, 0, strings.ApiKey, _apiKey);
        AddDetailRow(detail, 1, strings.Endpoint, _endpoint);
        AddDetailRow(detail, 2, strings.Model, _model);

        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.LeftToRight,
            AutoSize = true
        };
        _saveProvider.Text = strings.Save;
        _saveProvider.Click += (_, _) => SaveProvider();
        buttons.Controls.Add(_saveProvider);
        _useCurrent.Text = strings.UseAsCurrent;
        _useCurrent.AutoSize = true;
        _useCurrent.Click += (_, _) =>
        {
            if (_providerList.SelectedItem is ProviderId provider)
            {
                SelectProviderAndRefresh(provider);
            }
        };
        buttons.Controls.Add(_useCurrent);
        detail.Controls.Add(buttons, 1, 3);

        root.Controls.Add(detail, 1, 0);

        page.Controls.Add(root);
        _tabs.TabPages.Add(page);
    }

    private string ProviderRowLabel(ProviderId provider)
    {
        var strings = _host.Strings;
        return _host.Credentials.HasSecret(provider)
            ? $"{strings.ProviderName(provider)} ✓"
            : strings.IsEnglish
                ? $"{strings.ProviderName(provider)} ({strings.NotConfigured})"
                : $"{strings.ProviderName(provider)}（{strings.NotConfigured}）";
    }

    private void LoadProviderFields()
    {
        if (_providerList.SelectedItem is not ProviderId provider)
        {
            return;
        }
        var settings = _settings().Providers[provider];
        _apiKey.Text = "";
        _apiKey.PlaceholderText = _host.Credentials.HasSecret(provider)
            ? _host.Strings.SavedLeaveBlank
            : _host.Strings.PasteApiKey;
        _endpoint.Text = settings.Endpoint;
        _model.Text = settings.Model;
        _useCurrent.Enabled = _host.Credentials.HasSecret(provider);
    }

    private void SaveProvider()
    {
        if (_providerList.SelectedItem is not ProviderId provider)
        {
            return;
        }
        var strings = _host.Strings;
        var endpointTextValue = _endpoint.Text.Trim();
        var modelTextValue = _model.Text.Trim();

        if (!Uri.TryCreate(endpointTextValue, UriKind.Absolute, out var endpoint)
            || endpoint.Scheme != Uri.UriSchemeHttps
            || string.IsNullOrWhiteSpace(endpoint.Host))
        {
            ShowStatus(strings.InvalidEndpoint, isError: true);
            return;
        }
        if (modelTextValue.Length == 0)
        {
            ShowStatus(strings.MissingModel, isError: true);
            return;
        }
        var normalizedKey = _apiKey.Text.Trim();
        try
        {
            if (normalizedKey.Length > 0)
            {
                _host.Credentials.Save(provider, normalizedKey);
            }
            if (!_host.Credentials.HasSecret(provider))
            {
                ShowStatus(strings.MissingApiKey, isError: true);
                return;
            }
        }
        catch (Exception exception)
        {
            ShowStatus(exception.Message, isError: true);
            return;
        }

        var previous = _settings().Providers[provider];
        _settings().Providers[provider] = new ProviderSettings
        {
            Endpoint = endpointTextValue,
            Model = modelTextValue
        };
        if (!_host.Persist())
        {
            _settings().Providers[provider] = previous;
            return;
        }
        _apiKey.Text = "";
        LoadProviderFields();
        RefreshProviderList();
        ShowStatus(strings.SavedHint, isError: false);
    }

    private void RefreshProviderList()
    {
        var selected = _providerList.SelectedItem;
        _providerList.BeginUpdate();
        _providerList.Items.Clear();
        foreach (var provider in ProviderCatalog.All)
        {
            _providerList.Items.Add(provider);
        }
        if (selected is ProviderId id && ProviderCatalog.All.Any(p => p.Id == id))
        {
            _providerList.SelectedItem = id;
        }
        _providerList.EndUpdate();
    }

    private void SelectProviderAndRefresh(ProviderId provider)
    {
        var hadKey = _host.Credentials.HasSecret(provider);
        if (!hadKey)
        {
            SaveProvider();
            if (!_host.Credentials.HasSecret(provider))
            {
                return;
            }
        }
        _host.SelectProviderFromSettings(provider);
        RefreshProviderList();
        LoadProviderFields();
    }

    // MARK: 快捷键

    private void BuildHotKeyTab(UiStrings strings)
    {
        var page = new TabPage(strings.HotKeyTab);
        var layout = NewFormLayout();

        _hotKeyValue.Text = HotKeyDisplay(_settings().HotKey);
        _hotKeyValue.Font = new Font(FontFamily.GenericMonospace, 10);
        AddDetailRow(layout, 0, strings.HotKey, _hotKeyValue, isEditor: false);

        var buttons = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true
        };
        _changeHotKey.Text = strings.HotKeySettings;
        _changeHotKey.Click += (_, _) => ChangeHotKey();
        buttons.Controls.Add(_changeHotKey);
        _restoreHotKey.Text = strings.RestoreDefault;
        _restoreHotKey.Click += (_, _) => _host.ApplyHotKey(new HotKeySettings());
        buttons.Controls.Add(_restoreHotKey);
        layout.Controls.Add(buttons, 1, 1);

        page.Controls.Add(layout);
        _tabs.TabPages.Add(page);
    }

    private void ChangeHotKey()
    {
        using var form = new HotKeyConfigurationForm(_settings().HotKey, _host.Strings);
        if (form.ShowDialog(this) == DialogResult.OK)
        {
            _host.ApplyHotKey(form.SelectedHotKey);
            _hotKeyValue.Text = HotKeyDisplay(_settings().HotKey);
        }
    }

    // MARK: 通用

    private void BuildGeneralTab(UiStrings strings)
    {
        var page = new TabPage(strings.GeneralTab);
        var layout = NewFormLayout();

        AddCombo(layout, strings.InterfaceLanguage, _interfaceLanguage,
            Enum.GetValues<InterfaceLanguage>()
                .Where(language => language != InterfaceLanguage.Automatic),
            language => strings.InterfaceLanguageName(language),
            UiStrings.For(_settings().InterfaceLanguage).Language,
            value => CloseAfterLanguageChange(value));
        layout.Controls.Add(new Label
        {
            Text = "",
            AutoSize = true
        }, 1, layout.RowCount);

        page.Controls.Add(layout);
        _tabs.TabPages.Add(page);

        if (_preselectProvider.HasValue)
        {
            _tabs.SelectedIndex = 1;
            _providerList.SelectedItem = _preselectProvider.Value;
            LoadProviderFields();
        }
    }

    private void CloseAfterLanguageChange(InterfaceLanguage resolved)
    {
        _host.ChangeInterfaceLanguage(resolved);
        Close();
    }

    // MARK: 共用小件

    private AppSettings _settings() => _host.Settings;

    private static TableLayoutPanel NewFormLayout()
    {
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(16),
            ColumnCount = 2,
            RowCount = 6,
            AutoSize = true
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 120));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        for (var row = 0; row < 6; row++)
        {
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        }
        return layout;
    }

    private static void AddDetailRow(
        TableLayoutPanel layout,
        int row,
        string label,
        Control editor,
        bool isEditor = true)
    {
        layout.Controls.Add(new Label
        {
            Text = label,
            TextAlign = ContentAlignment.MiddleRight,
            Dock = DockStyle.Fill,
            AutoSize = false
        }, 0, row);
        editor.Dock = DockStyle.Fill;
        layout.Controls.Add(editor, 1, row);
        if (isEditor)
        {
            editor.Margin = new Padding(3, 8, 3, 3);
        }
    }

    private void AddCombo<T>(
        TableLayoutPanel layout,
        string label,
        ComboBox combo,
        IEnumerable<T> values,
        Func<T, string> display,
        T selected,
        Action<T> onSelected) where T : notnull
    {
        combo.DropDownStyle = ComboBoxStyle.DropDownList;
        combo.Dock = DockStyle.Fill;
        foreach (var value in values)
        {
            combo.Items.Add(value);
        }
        combo.SelectedItem = selected;
        combo.Format += (_, args) =>
        {
            if (args.ListItem is T item)
            {
                args.Value = display(item);
            }
        };
        combo.SelectedIndexChanged += (_, _) =>
        {
            if (combo.SelectedItem is T item)
            {
                onSelected(item);
            }
        };

        var row = layout.RowCount - 1;
        layout.Controls.Add(new Label
        {
            Text = label,
            TextAlign = ContentAlignment.MiddleRight,
            Dock = DockStyle.Fill,
            AutoSize = false
        }, 0, row);
        layout.Controls.Add(combo, 1, row);
        layout.RowCount += 1;
    }

    private void ApplyPreference<T>(
        Func<T> getValue,
        Action<T> setValue,
        T value)
    {
        var previousValue = getValue();
        setValue(value);
        if (!_host.Persist())
        {
            setValue(previousValue);
        }
    }

    private void ShowStatus(string message, bool isError) =>
        _status.Text = message;

    private static string HotKeyDisplay(HotKeySettings settings)
    {
        var parts = new List<string>();
        if (settings.Modifiers.HasFlag(HotKeyModifiers.Control)) parts.Add("Ctrl");
        if (settings.Modifiers.HasFlag(HotKeyModifiers.Alt)) parts.Add("Alt");
        if (settings.Modifiers.HasFlag(HotKeyModifiers.Shift)) parts.Add("Shift");
        if (settings.Modifiers.HasFlag(HotKeyModifiers.Win)) parts.Add("Win");
        var virtualKey = settings.VirtualKey;
        if (virtualKey is >= 0x41 and <= 0x5A || virtualKey is >= 0x30 and <= 0x39)
        {
            parts.Add(((char)virtualKey).ToString());
        }
        else if (virtualKey is >= 0x70 and <= 0x7B)
        {
            parts.Add($"F{virtualKey - 0x6F}");
        }
        else
        {
            parts.Add($"0x{virtualKey:X2}");
        }
        return string.Join("+", parts);
    }
}
