using KEYI.Core;
using System.Net.Http;

namespace KEYI.Windows;

internal sealed class AppController : IDisposable, ISettingsDialogHost
{
    private readonly SettingsStore _settingsStore = new();
    private readonly CredentialStore _credentials = new();
    private readonly FocusedTextClient _focusedText = new();
    private readonly GlobalHotKeyManager _hotKey = new();
    private readonly HttpClient _httpClient = new();
    private readonly NotifyIcon _notifyIcon = new();
    private readonly ContextMenuStrip _menu = new();
    private readonly System.Windows.Forms.Timer _foregroundTimer = new();
    private readonly ToolStripMenuItem _statusItem = new() { Enabled = false };
    private readonly ToolStripMenuItem _providerMenu = new();
    private readonly ToolStripMenuItem _targetLanguageMenu = new();
    private readonly ToolStripMenuItem _sceneMenu = new();
    private readonly ToolStripMenuItem _styleMenu = new();
    private readonly ToolStripMenuItem _interfaceLanguageMenu = new();
    private readonly ToolStripMenuItem _hotKeyLabel = new() { Enabled = false };
    private readonly ToolStripMenuItem _translateItem = new();
    private readonly ToolStripMenuItem _settingsItem = new();
    private readonly ToolStripMenuItem _configureHotKeyItem = new();
    private readonly ToolStripMenuItem _restoreHotKeyItem = new();
    private readonly ToolStripMenuItem _checkUpdatesItem = new();
    private readonly ToolStripMenuItem _exitItem = new();
    private readonly ToolStripMenuItem _styleScopeHint = new()
    {
        Enabled = false,
        Visible = false
    };

    private AppSettings _settings = new();
    private UiStrings _strings = UiStrings.For(InterfaceLanguage.Automatic);
    private nint _lastExternalWindow;
    private bool _busy;
    private bool _disposed;

    public void Initialize()
    {
        _settings = _settingsStore.Load();
        UiStrings.SetCurrent(_settings.InterfaceLanguage);
        _strings = UiStrings.For(_settings.InterfaceLanguage);
        BuildMenu();

        _notifyIcon.Icon = SystemIcons.Information;
        _notifyIcon.Text = $"{_strings.AppName} - {_strings.Ready}";
        _notifyIcon.ContextMenuStrip = _menu;
        _notifyIcon.Visible = true;
        _notifyIcon.DoubleClick += async (_, _) => await TranslateFromTrayAsync();

        _hotKey.Pressed += async (_, _) => await TranslateAsync();
        RegisterInitialHotKey();

        _foregroundTimer.Interval = 250;
        _foregroundTimer.Tick += (_, _) => TrackForegroundWindow();
        _foregroundTimer.Start();
        TrackForegroundWindow();

        if (!_credentials.HasSecret(_settings.SelectedProvider))
        {
            ShowBalloon(
                _strings.ApiRequiredTitle,
                _strings.ConfigureApiHint(_settings.SelectedProvider),
                ToolTipIcon.Info);
        }
    }

    private void BuildMenu()
    {
        _settingsItem.Text = _strings.Settings;
        _settingsItem.Click += (_, _) => ShowSettings();
        _menu.Items.Add(_settingsItem);
        _menu.Items.Add(new ToolStripSeparator());

        foreach (var provider in ProviderCatalog.All)
        {
            var providerItem = new ToolStripMenuItem(_strings.ProviderName(provider.Id))
            {
                Tag = provider.Id,
                CheckOnClick = false
            };
            providerItem.Click += (_, _) => SelectProvider(provider.Id);
            _providerMenu.DropDownItems.Add(providerItem);
        }

        foreach (var scene in Enum.GetValues<TranslationScene>())
        {
            var item = new ToolStripMenuItem(_strings.SceneName(scene)) { Tag = scene };
            item.Click += (_, _) => ApplyPreference(
                () => _settings.Scene,
                value => _settings.Scene = value,
                scene);
            _sceneMenu.DropDownItems.Add(item);
        }

        foreach (var language in Enum.GetValues<TranslationLanguage>())
        {
            var item = new ToolStripMenuItem(_strings.LanguageName(language)) { Tag = language };
            item.Click += (_, _) =>
            {
                if (_busy)
                {
                    return;
                }
                ApplyPreference(
                    () => _settings.TargetLanguage,
                    value => _settings.TargetLanguage = value,
                    language);
            };
            _targetLanguageMenu.DropDownItems.Add(item);
        }

        foreach (var style in Enum.GetValues<EnglishStyle>())
        {
            var item = new ToolStripMenuItem(_strings.StyleName(style)) { Tag = style };
            item.Click += (_, _) => ApplyPreference(
                () => _settings.EnglishStyle,
                value => _settings.EnglishStyle = value,
                style);
            _styleMenu.DropDownItems.Add(item);
        }

        _menu.Items.Add(_providerMenu);
        _menu.Items.Add(_targetLanguageMenu);
        _menu.Items.Add(_sceneMenu);
        _menu.Items.Add(_styleMenu);
        _menu.Items.Add(_styleScopeHint);
        _menu.Items.Add(new ToolStripSeparator());

        _checkUpdatesItem.Text = _strings.CheckUpdates;
        _checkUpdatesItem.Click += (_, _) => ShowReleaseInformation();
        _menu.Items.Add(_checkUpdatesItem);

        _exitItem.Text = _strings.Exit;
        _exitItem.Click += (_, _) => Application.ExitThread();
        _menu.Items.Add(_exitItem);

        _menu.Opening += (_, _) => UpdateMenuChecks();
        UpdateMenuChecks();
    }

    private void BuildInterfaceLanguageMenu()
    {
        _interfaceLanguageMenu.Text = _strings.InterfaceLanguageValue(
            _settings.InterfaceLanguage);
        foreach (var language in Enum.GetValues<InterfaceLanguage>())
        {
            var item = new ToolStripMenuItem(_strings.InterfaceLanguageName(language))
            {
                Tag = language
            };
            item.Click += (_, _) => SelectInterfaceLanguage(language);
            _interfaceLanguageMenu.DropDownItems.Add(item);
        }
    }

    private void SelectInterfaceLanguage(InterfaceLanguage language)
    {
        var previous = _settings.InterfaceLanguage;
        _settings.InterfaceLanguage = language;
        if (!SaveSettings())
        {
            _settings.InterfaceLanguage = previous;
            return;
        }

        _strings = UiStrings.For(language);
        UiStrings.SetCurrent(language);
        UpdateMenuChecks();
        SetStatus(_strings.InterfaceLanguageUpdated);
    }

    private async Task TranslateFromTrayAsync()
    {
        if (_lastExternalWindow == nint.Zero || !NativeMethods.IsWindow(_lastExternalWindow))
        {
            ShowError(_strings.NoFocusedWindow);
            return;
        }
        NativeMethods.SetForegroundWindow(_lastExternalWindow);
        await Task.Delay(180);
        await TranslateAsync();
    }

    private async Task TranslateAsync()
    {
        if (_busy)
        {
            return;
        }

        _busy = true;
        try
        {
            var provider = ProviderCatalog.Get(_settings.SelectedProvider);
            var apiKey = _credentials.Read(provider.Id);
            if (string.IsNullOrWhiteSpace(apiKey))
            {
                SetStatus(_strings.ConfigureProviderFirst(provider.Id));
                ShowSettings(provider.Id);
                return;
            }

            SetStatus(_strings.ReadingInput);
            var snapshot = await _focusedText.CaptureAsync();
            var providerSettings = _settings.Providers[provider.Id];
            if (!Uri.TryCreate(providerSettings.Endpoint, UriKind.Absolute, out var endpoint))
            {
                throw new TranslationException(
                    TranslationErrorKind.InvalidEndpoint,
                    "Provider endpoint is not an absolute URL");
            }

            SetStatus(_strings.UsingProvider(provider.Id));
            var client = new OpenAiTranslationClient(_httpClient);
            var translated = await client.TranslateAsync(
                new TextTranslationRequest(
                    snapshot.SourceText,
                    snapshot.ContextText,
                    _settings.TargetLanguage,
                    _settings.Scene,
                    _settings.EnglishStyle),
                new ApiProviderConfiguration(
                    provider.Id,
                    apiKey,
                    endpoint,
                    providerSettings.Model));

            SetStatus(_strings.WritingInput);
            await _focusedText.ReplaceAsync(snapshot, translated);
            SetStatus(_strings.TranslationComplete);
        }
        catch (Exception exception)
        {
            ShowError(UserMessage(exception));
        }
        finally
        {
            _busy = false;
        }
    }

    private void SelectProvider(ProviderId providerId)
    {
        if (!_credentials.HasSecret(providerId))
        {
            ShowSettings(providerId);
            return;
        }
        ApplySelectedProvider(providerId);
    }

    private void ApplySelectedProvider(ProviderId providerId)
    {
        var previousProvider = _settings.SelectedProvider;
        _settings.SelectedProvider = providerId;
        if (!SaveSettings())
        {
            _settings.SelectedProvider = previousProvider;
            UpdateMenuChecks();
            return;
        }
        UpdateMenuChecks();
        SetStatus(_strings.SelectedProvider(providerId));
    }

    // MARK: 设置窗口（ISettingsDialogHost）

    private SettingsForm? _settingsForm;

    public void ShowSettings(ProviderId? preselectProvider = null)
    {
        if (_settingsForm is { IsDisposed: false } existing)
        {
            existing.Activate();
            return;
        }
        var form = new SettingsForm(this, preselectProvider);
        form.FormClosed += (_, _) =>
        {
            if (ReferenceEquals(_settingsForm, form))
            {
                _settingsForm = null;
            }
        };
        _settingsForm = form;
        form.Show();
    }

    AppSettings ISettingsDialogHost.Settings => _settings;

    UiStrings ISettingsDialogHost.Strings => _strings;

    CredentialStore ISettingsDialogHost.Credentials => _credentials;

    bool ISettingsDialogHost.Persist() => SaveSettings();

    void ISettingsDialogHost.ApplyHotKey(HotKeySettings settings) => ApplyHotKey(settings);

    void ISettingsDialogHost.SelectProviderFromSettings(ProviderId providerId) =>
        ApplySelectedProvider(providerId);

    void ISettingsDialogHost.ChangeInterfaceLanguage(InterfaceLanguage language)
    {
        var reopen = _settingsForm is { IsDisposed: false };
        SelectInterfaceLanguage(language);
        if (!reopen)
        {
            return;
        }
        // 等旧窗口走完 FormClosed 再开新窗口，避免字段被误清。
        var context = SynchronizationContext.Current;
        void Reopen() => ShowSettings();
        if (context is not null)
        {
            context.Post(_ => Reopen(), null);
        }
        else
        {
            Reopen();
        }
    }

    private void ConfigureHotKey()
    {
        using var form = new HotKeyConfigurationForm(_settings.HotKey, _strings);
        if (form.ShowDialog() == DialogResult.OK)
        {
            ApplyHotKey(form.SelectedHotKey);
        }
    }

    private void ApplyHotKey(HotKeySettings settings)
    {
        if (!_hotKey.TryReplace(settings))
        {
            MessageBox.Show(
                _strings.HotKeyUnavailable(HotKeyDisplay(settings)),
                _strings.AppName,
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
            return;
        }
        var previousSettings = _settings.HotKey;
        _settings.HotKey = settings;
        if (!SaveSettings())
        {
            _settings.HotKey = previousSettings;
            if (!_hotKey.TryReplace(previousSettings))
            {
                ShowError(_strings.SaveHotKeyFailed);
            }
            UpdateMenuChecks();
            return;
        }
        UpdateMenuChecks();
        SetStatus(_strings.HotKeyUpdated(HotKeyDisplay(settings)));
    }

    private void ShowReleaseInformation()
    {
        MessageBox.Show(
            _strings.IsEnglish
                ? "The current release includes an unsigned Windows experimental binary without auto-update. SmartScreen may warn, and native acceptance is not complete."
                : "当前 Release 提供未签名的 Windows 实验二进制，不包含自动更新；SmartScreen 可能显示警告，正式原生验收尚未完成。",
            _strings.AppName,
            MessageBoxButtons.OK,
            MessageBoxIcon.Information);
    }

    private void RegisterInitialHotKey()
    {
        if (_hotKey.TryReplace(_settings.HotKey))
        {
            return;
        }

        var fallback = new HotKeySettings();
        if (_hotKey.TryReplace(fallback))
        {
            _settings.HotKey = fallback;
            if (SaveSettings())
            {
                SetStatus(_strings.FallbackHotKey("Alt+T"));
            }
        }
        else
        {
            ShowError(_strings.HotKeyRegistrationFailed);
        }
    }

    private void UpdateMenuChecks()
    {
        foreach (ToolStripMenuItem item in _providerMenu.DropDownItems)
        {
            var providerId = (ProviderId)item.Tag!;
            item.Checked = providerId == _settings.SelectedProvider;
            var providerName = _strings.ProviderName(providerId);
            item.Text = _credentials.HasSecret(providerId)
                ? providerName
                : _strings.ProviderNotConfigured(providerId);
        }
        foreach (ToolStripMenuItem item in _sceneMenu.DropDownItems)
        {
            item.Checked = (TranslationScene)item.Tag! == _settings.Scene;
        }
        foreach (ToolStripMenuItem item in _targetLanguageMenu.DropDownItems)
        {
            item.Checked = (TranslationLanguage)item.Tag! == _settings.TargetLanguage;
        }
        foreach (ToolStripMenuItem item in _styleMenu.DropDownItems)
        {
            item.Checked = (EnglishStyle)item.Tag! == _settings.EnglishStyle;
        }

        _providerMenu.Text = _strings.TranslationMethod;
        _targetLanguageMenu.Text = _strings.TargetLanguage;
        _targetLanguageMenu.Enabled = !_busy;
        _sceneMenu.Text = _strings.Scene;
        _styleMenu.Text = _strings.Style;
        var styleEnabled = TranslationPromptBuilder.UsesEnglishStyle(
            _settings.TargetLanguage,
            _settings.Scene);
        _styleMenu.Enabled = styleEnabled;
        _styleScopeHint.Visible = !styleEnabled;
        _styleScopeHint.Text = _strings.SceneStyleHint(
            supportsScene: true,
            supportsStyle: styleEnabled,
            scene: _settings.Scene);
        _interfaceLanguageMenu.Text = _strings.InterfaceLanguageValue(
            _settings.InterfaceLanguage);
        foreach (ToolStripMenuItem item in _interfaceLanguageMenu.DropDownItems)
        {
            var language = (InterfaceLanguage)item.Tag!;
            item.Checked = language == _settings.InterfaceLanguage;
            item.Text = _strings.InterfaceLanguageName(language);
        }
        _hotKeyLabel.Text = $"{_strings.HotKey}  {HotKeyDisplay(_settings.HotKey)}";
    }

    private void TrackForegroundWindow()
    {
        var window = NativeMethods.GetForegroundWindow();
        if (window == nint.Zero)
        {
            return;
        }
        NativeMethods.GetWindowThreadProcessId(window, out var processId);
        if (processId != (uint)Environment.ProcessId)
        {
            _lastExternalWindow = window;
        }
    }

    private void ApplyPreference<T>(
        Func<T> getValue,
        Action<T> setValue,
        T value)
    {
        var previousValue = getValue();
        setValue(value);
        if (!SaveSettings())
        {
            setValue(previousValue);
        }
        UpdateMenuChecks();
    }

    private bool SaveSettings()
    {
        try
        {
            _settingsStore.Save(_settings);
            return true;
        }
        catch (Exception exception)
        {
            ShowError(_strings.SaveSettingsFailed(UserMessage(exception)));
            return false;
        }
    }

    private void SetStatus(string message)
    {
        _statusItem.Text = message;
        _notifyIcon.Text = message.Length <= 55
            ? $"{_strings.AppName} - {message}"
            : _strings.AppName;
    }

    private void ShowError(string message)
    {
        SetStatus(message);
        ShowBalloon(_strings.AppName, message, ToolTipIcon.Warning);
    }

    private void ShowBalloon(string title, string message, ToolTipIcon icon)
    {
        _notifyIcon.BalloonTipTitle = title;
        _notifyIcon.BalloonTipText = message;
        _notifyIcon.BalloonTipIcon = icon;
        _notifyIcon.ShowBalloonTip(3500);
    }

    private string UserMessage(Exception exception) => exception switch
    {
        OperationCanceledException => _strings.TimeoutOrCancelled,
        TranslationException translation => _strings.TranslationFailure(translation),
        _ when !string.IsNullOrWhiteSpace(exception.Message) => exception.Message,
        _ => _strings.OperationFailed
    };

    private static string HotKeyDisplay(HotKeySettings settings)
    {
        var parts = new List<string>();
        if (settings.Modifiers.HasFlag(HotKeyModifiers.Control)) parts.Add("Ctrl");
        if (settings.Modifiers.HasFlag(HotKeyModifiers.Alt)) parts.Add("Alt");
        if (settings.Modifiers.HasFlag(HotKeyModifiers.Shift)) parts.Add("Shift");
        if (settings.Modifiers.HasFlag(HotKeyModifiers.Win)) parts.Add("Win");
        parts.Add(VirtualKeyDisplay(settings.VirtualKey));
        return string.Join("+", parts);
    }

    private static string VirtualKeyDisplay(int virtualKey)
    {
        if (virtualKey is >= 0x41 and <= 0x5A
            || virtualKey is >= 0x30 and <= 0x39)
        {
            return ((char)virtualKey).ToString();
        }
        if (virtualKey is >= 0x70 and <= 0x7B)
        {
            return $"F{virtualKey - 0x6F}";
        }
        return $"0x{virtualKey:X2}";
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _foregroundTimer.Stop();
        _foregroundTimer.Dispose();
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _menu.Dispose();
        _hotKey.Dispose();
        _httpClient.Dispose();
    }
}
