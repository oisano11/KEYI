using KEYI.Core;
using System.Net.Http;

namespace KEYI.Windows;

internal sealed class AppController : IDisposable
{
    private readonly SettingsStore _settingsStore = new();
    private readonly CredentialStore _credentials = new();
    private readonly FocusedTextClient _focusedText = new();
    private readonly GlobalHotKeyManager _hotKey = new();
    private readonly HttpClient _httpClient = new();
    private readonly NotifyIcon _notifyIcon = new();
    private readonly ContextMenuStrip _menu = new();
    private readonly System.Windows.Forms.Timer _foregroundTimer = new();
    private readonly ToolStripMenuItem _statusItem = new("就绪") { Enabled = false };
    private readonly ToolStripMenuItem _providerMenu = new("翻译方式");
    private readonly ToolStripMenuItem _targetLanguageMenu = new("目标语言");
    private readonly ToolStripMenuItem _sceneMenu = new("翻译场景");
    private readonly ToolStripMenuItem _styleMenu = new("英语风格");
    private readonly ToolStripMenuItem _apiMenu = new("添加/管理模型 API");
    private readonly ToolStripMenuItem _hotKeyLabel = new() { Enabled = false };
    private readonly ToolStripMenuItem _styleScopeHint = new()
    {
        Enabled = false,
        Visible = false
    };

    private AppSettings _settings = new();
    private nint _lastExternalWindow;
    private bool _busy;
    private bool _disposed;

    public void Initialize()
    {
        _settings = _settingsStore.Load();
        BuildMenu();

        _notifyIcon.Icon = SystemIcons.Information;
        _notifyIcon.Text = "KEYI 可译 - 就绪";
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
                "需要配置模型 API",
                $"请右键 KEYI 可译托盘图标，配置 {ProviderCatalog.Get(_settings.SelectedProvider).DisplayName} API。",
                ToolTipIcon.Info);
        }
    }

    private void BuildMenu()
    {
        _menu.Items.Add(_statusItem);
        _menu.Items.Add(new ToolStripSeparator());

        var translate = new ToolStripMenuItem("翻译当前输入框");
        translate.Click += async (_, _) => await TranslateFromTrayAsync();
        _menu.Items.Add(translate);

        foreach (var provider in ProviderCatalog.All)
        {
            var providerItem = new ToolStripMenuItem(provider.DisplayName)
            {
                Tag = provider.Id,
                CheckOnClick = false
            };
            providerItem.Click += (_, _) => SelectProvider(provider.Id);
            _providerMenu.DropDownItems.Add(providerItem);

            var apiItem = new ToolStripMenuItem(provider.DisplayName)
            {
                Tag = provider.Id
            };
            apiItem.Click += (_, _) => ConfigureProvider(provider.Id);
            _apiMenu.DropDownItems.Add(apiItem);
        }

        foreach (var scene in Enum.GetValues<TranslationScene>())
        {
            var item = new ToolStripMenuItem(scene.DisplayName()) { Tag = scene };
            item.Click += (_, _) => ApplyPreference(
                () => _settings.Scene,
                value => _settings.Scene = value,
                scene);
            _sceneMenu.DropDownItems.Add(item);
        }

        foreach (var language in Enum.GetValues<TranslationLanguage>())
        {
            var item = new ToolStripMenuItem(language.DisplayName()) { Tag = language };
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
            var item = new ToolStripMenuItem(style.DisplayName()) { Tag = style };
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
        _menu.Items.Add(_apiMenu);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(_hotKeyLabel);

        var configureHotKey = new ToolStripMenuItem("设置快捷键...");
        configureHotKey.Click += (_, _) => ConfigureHotKey();
        _menu.Items.Add(configureHotKey);

        var restoreHotKey = new ToolStripMenuItem("恢复默认快捷键");
        restoreHotKey.Click += (_, _) => ApplyHotKey(new HotKeySettings());
        _menu.Items.Add(restoreHotKey);
        _menu.Items.Add(new ToolStripSeparator());

        var checkForUpdates = new ToolStripMenuItem("版本与发布说明");
        checkForUpdates.Click += (_, _) => ShowReleaseInformation();
        _menu.Items.Add(checkForUpdates);

        var exit = new ToolStripMenuItem("退出 KEYI 可译");
        exit.Click += (_, _) => Application.ExitThread();
        _menu.Items.Add(exit);

        _menu.Opening += (_, _) => UpdateMenuChecks();
        UpdateMenuChecks();
    }

    private async Task TranslateFromTrayAsync()
    {
        if (_lastExternalWindow == nint.Zero || !NativeMethods.IsWindow(_lastExternalWindow))
        {
            ShowError("没有找到最近使用的输入窗口");
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
                SetStatus($"请先配置 {provider.DisplayName} API");
                ConfigureProvider(provider.Id);
                return;
            }

            SetStatus("正在读取当前输入框");
            var snapshot = await _focusedText.CaptureAsync();
            var providerSettings = _settings.Providers[provider.Id];
            if (!Uri.TryCreate(providerSettings.Endpoint, UriKind.Absolute, out var endpoint))
            {
                throw new TranslationException("Endpoint 必须是有效的 HTTPS 地址");
            }

            SetStatus($"正在使用 {provider.DisplayName} 翻译");
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

            SetStatus("正在写回当前输入框");
            await _focusedText.ReplaceAsync(snapshot, translated);
            SetStatus("翻译完成");
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
        if (!_credentials.HasSecret(providerId) && !ConfigureProvider(providerId))
        {
            return;
        }
        var previousProvider = _settings.SelectedProvider;
        _settings.SelectedProvider = providerId;
        if (!SaveSettings())
        {
            _settings.SelectedProvider = previousProvider;
            UpdateMenuChecks();
            return;
        }
        UpdateMenuChecks();
        SetStatus($"已选择 {ProviderCatalog.Get(providerId).DisplayName}");
    }

    private bool ConfigureProvider(ProviderId providerId)
    {
        var provider = ProviderCatalog.Get(providerId);
        var hasStoredKey = _credentials.HasSecret(providerId);
        using var form = new ProviderConfigurationForm(
            provider,
            _settings.Providers[providerId],
            hasStoredKey);
        if (form.ShowDialog() != DialogResult.OK)
        {
            return false;
        }

        try
        {
            if (form.ApiKey.Length > 0)
            {
                _credentials.Save(providerId, form.ApiKey);
            }
            if (!_credentials.HasSecret(providerId))
            {
                throw new InvalidOperationException("API Key 不能为空");
            }
            var previousSettings = _settings.Providers[providerId];
            _settings.Providers[providerId] = new ProviderSettings
            {
                Endpoint = form.Endpoint,
                Model = form.ModelName
            };
            if (!SaveSettings())
            {
                _settings.Providers[providerId] = previousSettings;
                UpdateMenuChecks();
                return false;
            }
            UpdateMenuChecks();
            SetStatus($"已保存 {provider.DisplayName} API");
            return true;
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                UserMessage(exception),
                "KEYI 可译",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return false;
        }
    }

    private void ConfigureHotKey()
    {
        using var form = new HotKeyConfigurationForm(_settings.HotKey);
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
                $"快捷键 {HotKeyDisplay(settings)} 无法注册，可能已被其他应用占用。",
                "KEYI 可译",
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
                ShowError("保存快捷键失败，且原快捷键恢复失败，请重新设置");
            }
            UpdateMenuChecks();
            return;
        }
        UpdateMenuChecks();
        SetStatus($"快捷键已更新为 {HotKeyDisplay(settings)}");
    }

    private void ShowReleaseInformation()
    {
        MessageBox.Show(
            "当前 Release 提供未签名的 Windows 实验二进制，不包含自动更新；SmartScreen 可能显示警告，正式原生验收尚未完成。",
            "KEYI 可译",
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
                SetStatus("原快捷键不可用，已恢复 Alt+T");
            }
        }
        else
        {
            ShowError("全局快捷键注册失败，请从托盘菜单重新设置");
        }
    }

    private void UpdateMenuChecks()
    {
        foreach (ToolStripMenuItem item in _providerMenu.DropDownItems)
        {
            var providerId = (ProviderId)item.Tag!;
            item.Checked = providerId == _settings.SelectedProvider;
            item.Text = _credentials.HasSecret(providerId)
                ? ProviderCatalog.Get(providerId).DisplayName
                : $"{ProviderCatalog.Get(providerId).DisplayName}（未配置）";
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
        foreach (ToolStripMenuItem item in _apiMenu.DropDownItems)
        {
            var providerId = (ProviderId)item.Tag!;
            item.Text = _credentials.HasSecret(providerId)
                ? $"{ProviderCatalog.Get(providerId).DisplayName} ✓"
                : ProviderCatalog.Get(providerId).DisplayName;
        }

        _providerMenu.Text = $"翻译方式：{ProviderCatalog.Get(_settings.SelectedProvider).DisplayName}";
        _targetLanguageMenu.Text = $"目标语言：{_settings.TargetLanguage.DisplayName()}";
        _targetLanguageMenu.Enabled = !_busy;
        _sceneMenu.Text = $"翻译场景：{_settings.Scene.DisplayName()}";
        _styleMenu.Text = $"英语风格：{_settings.EnglishStyle.DisplayName()}";
        var styleEnabled = TranslationPromptBuilder.UsesEnglishStyle(
            _settings.TargetLanguage,
            _settings.Scene);
        _styleMenu.Enabled = styleEnabled;
        _styleScopeHint.Visible = !styleEnabled;
        _styleScopeHint.Text = _settings.Scene == TranslationScene.Business
            ? "商务场景优先准确表达，不使用英语风格"
            : "翻译场景适用于全部目标语言；英语风格仅适用于英语";
        _hotKeyLabel.Text = $"快捷键  {HotKeyDisplay(_settings.HotKey)}";
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
            ShowError($"保存设置失败：{UserMessage(exception)}");
            return false;
        }
    }

    private void SetStatus(string message)
    {
        _statusItem.Text = message;
        _notifyIcon.Text = message.Length <= 55 ? $"KEYI 可译 - {message}" : "KEYI 可译";
    }

    private void ShowError(string message)
    {
        SetStatus(message);
        ShowBalloon("KEYI 可译", message, ToolTipIcon.Warning);
    }

    private void ShowBalloon(string title, string message, ToolTipIcon icon)
    {
        _notifyIcon.BalloonTipTitle = title;
        _notifyIcon.BalloonTipText = message;
        _notifyIcon.BalloonTipIcon = icon;
        _notifyIcon.ShowBalloonTip(3500);
    }

    private static string UserMessage(Exception exception) => exception switch
    {
        OperationCanceledException => "翻译请求超时或已取消",
        _ when !string.IsNullOrWhiteSpace(exception.Message) => exception.Message,
        _ => "操作失败"
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
