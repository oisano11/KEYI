using KEYI.Core;

namespace KEYI.Windows;

internal sealed class HotKeyConfigurationForm : Form
{
    private readonly CheckBox _control = new() { Text = "Ctrl", AutoSize = true };
    private readonly CheckBox _alt = new() { Text = "Alt", AutoSize = true };
    private readonly CheckBox _shift = new() { Text = "Shift", AutoSize = true };
    private readonly CheckBox _win = new() { Text = "Win", AutoSize = true };
    private readonly ComboBox _key = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly UiStrings _strings;

    public HotKeySettings SelectedHotKey { get; private set; }

    public HotKeyConfigurationForm(HotKeySettings current, UiStrings strings)
    {
        SelectedHotKey = current;
        _strings = strings;
        Text = strings.HotKeySettings;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        MinimumSize = new Size(430, 0);
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;

        _control.Checked = current.Modifiers.HasFlag(HotKeyModifiers.Control);
        _alt.Checked = current.Modifiers.HasFlag(HotKeyModifiers.Alt);
        _shift.Checked = current.Modifiers.HasFlag(HotKeyModifiers.Shift);
        _win.Checked = current.Modifiers.HasFlag(HotKeyModifiers.Win);

        var keys = KeyOption.All;
        _key.DataSource = keys;
        _key.DisplayMember = nameof(KeyOption.Name);
        _key.SelectedItem = keys.FirstOrDefault(option => option.VirtualKey == current.VirtualKey)
            ?? keys[0];

        var layout = new TableLayoutPanel
        {
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            // Let the form size itself to the panel's preferred width at the active DPI.
            Dock = DockStyle.None,
            Padding = new Padding(16),
            ColumnCount = 1,
            RowCount = 3
        };
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.Controls.Add(new Label
        {
            Text = strings.IsEnglish
                ? "The combination must include Ctrl, Alt, or Win."
                : "组合键必须包含 Ctrl、Alt 或 Win。",
            AutoSize = true
        });

        var controls = new FlowLayoutPanel
        {
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Dock = DockStyle.Top,
            Margin = new Padding(0, 14, 0, 0),
            WrapContents = false
        };
        controls.Controls.AddRange([_control, _alt, _shift, _win, _key]);
        layout.Controls.Add(controls);

        var buttons = new FlowLayoutPanel
        {
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Dock = DockStyle.Top,
            FlowDirection = FlowDirection.RightToLeft,
            WrapContents = false
        };
        var save = new Button { Text = strings.Save, AutoSize = true };
        var cancel = new Button { Text = strings.Cancel, AutoSize = true, DialogResult = DialogResult.Cancel };
        save.Click += SaveClicked;
        buttons.Controls.Add(save);
        buttons.Controls.Add(cancel);
        layout.Controls.Add(buttons, 0, 2);

        Controls.Add(layout);
        AcceptButton = save;
        CancelButton = cancel;
    }

    private void SaveClicked(object? sender, EventArgs eventArgs)
    {
        var modifiers = HotKeyModifiers.None;
        if (_control.Checked) modifiers |= HotKeyModifiers.Control;
        if (_alt.Checked) modifiers |= HotKeyModifiers.Alt;
        if (_shift.Checked) modifiers |= HotKeyModifiers.Shift;
        if (_win.Checked) modifiers |= HotKeyModifiers.Win;

        if ((modifiers & (HotKeyModifiers.Control | HotKeyModifiers.Alt | HotKeyModifiers.Win)) == 0)
        {
            MessageBox.Show(
                this,
                _strings.IsEnglish
                    ? "The hotkey must include Ctrl, Alt, or Win."
                    : "快捷键必须包含 Ctrl、Alt 或 Win。",
                _strings.AppName,
                MessageBoxButtons.OK,
                MessageBoxIcon.Warning);
            return;
        }

        var key = (KeyOption)_key.SelectedItem!;
        SelectedHotKey = new HotKeySettings
        {
            Modifiers = modifiers,
            VirtualKey = key.VirtualKey
        };
        DialogResult = DialogResult.OK;
        Close();
    }

    private sealed record KeyOption(string Name, int VirtualKey)
    {
        public static List<KeyOption> All { get; } = Build();

        private static List<KeyOption> Build()
        {
            var values = new List<KeyOption>();
            values.AddRange(Enumerable.Range('A', 26).Select(value =>
                new KeyOption(((char)value).ToString(), value)));
            values.AddRange(Enumerable.Range('0', 10).Select(value =>
                new KeyOption(((char)value).ToString(), value)));
            values.AddRange(Enumerable.Range(1, 12).Select(value =>
                new KeyOption($"F{value}", 0x6F + value)));
            return values;
        }
    }
}
