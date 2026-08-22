using KEYI.Core;

namespace KEYI.Windows;

internal sealed class ProviderConfigurationForm : Form
{
    private readonly TextBox _apiKey = new();
    private readonly TextBox _endpoint = new();
    private readonly TextBox _model = new();
    private readonly bool _hasStoredKey;
    private readonly UiStrings _strings;

    public string ApiKey => _apiKey.Text.Trim();
    public string Endpoint => _endpoint.Text.Trim();
    public string ModelName => _model.Text.Trim();

    public ProviderConfigurationForm(
        ProviderDefinition provider,
        ProviderSettings settings,
        bool hasStoredKey,
        UiStrings strings)
    {
        _hasStoredKey = hasStoredKey;
        _strings = strings;
        Text = strings.ConfigureApi(provider.Id);
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        MinimumSize = new Size(620, 0);
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = true;

        _apiKey.UseSystemPasswordChar = true;
        _apiKey.PlaceholderText = hasStoredKey
            ? strings.SavedLeaveBlank
            : strings.PasteApiKey;
        _endpoint.Text = settings.Endpoint;
        _model.Text = settings.Model;

        var layout = new TableLayoutPanel
        {
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            // A docked root panel is excluded from the form's AutoSize width calculation.
            Dock = DockStyle.None,
            Padding = new Padding(16),
            ColumnCount = 2,
            RowCount = 5
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 500));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        AddField(layout, 0, strings.ApiKey, _apiKey);
        AddField(layout, 1, strings.Endpoint, _endpoint);
        AddField(layout, 2, strings.Model, _model);

        var note = new Label
        {
            AutoSize = true,
            ForeColor = SystemColors.GrayText,
            Text = strings.ApiStorageInfo,
            Margin = new Padding(0, 10, 0, 0)
        };
        layout.Controls.Add(note, 1, 3);

        var buttons = new FlowLayoutPanel
        {
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Dock = DockStyle.Top,
            FlowDirection = FlowDirection.RightToLeft,
            WrapContents = false
        };
        var save = new Button { Text = strings.Save, AutoSize = true, DialogResult = DialogResult.None };
        var cancel = new Button { Text = strings.Cancel, AutoSize = true, DialogResult = DialogResult.Cancel };
        save.Click += SaveClicked;
        buttons.Controls.Add(save);
        buttons.Controls.Add(cancel);
        layout.Controls.Add(buttons, 0, 4);
        layout.SetColumnSpan(buttons, 2);

        Controls.Add(layout);
        AcceptButton = save;
        CancelButton = cancel;
    }

    private static void AddField(
        TableLayoutPanel layout,
        int row,
        string labelText,
        TextBox field)
    {
        var label = new Label
        {
            Text = labelText,
            AutoSize = true,
            Anchor = AnchorStyles.Right,
            Margin = new Padding(0, 8, 12, 8)
        };
        field.Dock = DockStyle.Fill;
        field.Margin = new Padding(0, 5, 0, 5);
        layout.Controls.Add(label, 0, row);
        layout.Controls.Add(field, 1, row);
    }

    private void SaveClicked(object? sender, EventArgs eventArgs)
    {
        if (!_hasStoredKey && ApiKey.Length == 0)
        {
            ShowValidation(_strings.MissingApiKey);
            return;
        }
        if (!Uri.TryCreate(Endpoint, UriKind.Absolute, out var endpoint)
            || endpoint.Scheme != Uri.UriSchemeHttps
            || string.IsNullOrWhiteSpace(endpoint.Host))
        {
            ShowValidation(_strings.InvalidEndpoint);
            return;
        }
        if (ModelName.Length == 0)
        {
            ShowValidation(_strings.MissingModel);
            return;
        }
        DialogResult = DialogResult.OK;
        Close();
    }

    private void ShowValidation(string message)
    {
        MessageBox.Show(this, message, _strings.AppName, MessageBoxButtons.OK, MessageBoxIcon.Warning);
    }
}
