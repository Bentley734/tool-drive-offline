using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows.Forms;

// Constructed controls remain hidden. These checks do not run app startup or touch profiles.
public static class ThemeChecks
{
    static Assembly app;
    static int passed;
    static object Create(string name, params object[] arguments) { return Activator.CreateInstance(app.GetType("ToolDriveOffline." + name, true), arguments); }
    static object Get(object target, string name) { return target.GetType().GetProperty(name).GetValue(target, null); }
    static void Set(object target, string name, object value) { target.GetType().GetProperty(name).SetValue(target, value, null); }
    static void Assert(bool condition, string message) { if (!condition) throw new Exception(message); passed++; Console.WriteLine("PASS " + message); }
    static void Key(Control control, Keys key)
    {
        control.GetType().GetMethod("OnKeyDown", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(control, new object[] { new KeyEventArgs(key) });
    }
    static IEnumerable<Control> Walk(Control root)
    {
        yield return root;
        foreach (Control child in root.Controls) foreach (Control nested in Walk(child)) yield return nested;
    }
    static void Checks()
    {
        using (var picker = (Control)Create("ThemedDropDown"))
        {
            var items = (IList)Get(picker, "Items");
            items.Add("1991"); items.Add("1992"); items.Add("2026");
            Set(picker, "SelectedIndex", 0);
            Assert(Convert.ToString(Get(picker, "SelectedItem")) == "1991", "custom dropdown preserves item selection");
            Set(picker, "SelectedItem", "2026");
            Assert(Convert.ToInt32(Get(picker, "SelectedIndex")) == 2, "custom dropdown selects an existing item by identity");
            Key(picker, Keys.Home);
            Assert(Convert.ToInt32(Get(picker, "SelectedIndex")) == 0, "Home selects the first dropdown item");
            Key(picker, Keys.Down);
            Assert(Convert.ToInt32(Get(picker, "SelectedIndex")) == 1, "arrow keys change a closed dropdown's value");
            Key(picker, Keys.End);
            Assert(Convert.ToInt32(Get(picker, "SelectedIndex")) == 2, "End selects the final dropdown item");
            Assert(picker.AccessibilityObject.Role == AccessibleRole.ComboBox, "custom dropdown retains its accessibility role");
            items.Clear();
            Assert(Convert.ToInt32(Get(picker, "SelectedIndex")) == -1 && Get(picker, "SelectedItem") == null, "refreshing dropdown items clears stale selections");
        }
        using (var rating = (Control)Create("ThemedNumberBox"))
        {
            Set(rating, "Minimum", 0M); Set(rating, "Maximum", 10M); Set(rating, "Increment", 0.5M); Set(rating, "DecimalPlaces", 1);
            Set(rating, "Value", 8.5M);
            Assert((decimal)Get(rating, "Value") == 8.5M, "custom rating input retains half-point sound ratings");
            var editor = Walk(rating).OfType<TextBox>().Single();
            Key(editor, Keys.Up);
            Assert((decimal)Get(rating, "Value") == 9M, "rating arrow keys use the configured increment");
            editor.Text = "7.5";
            editor.GetType().GetMethod("OnLostFocus", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(editor, new object[] { EventArgs.Empty });
            Assert((decimal)Get(rating, "Value") == 7.5M, "typed rating values commit when focus leaves");
            editor.Text = "not a rating";
            editor.GetType().GetMethod("OnLostFocus", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(editor, new object[] { EventArgs.Empty });
            Assert((decimal)Get(rating, "Value") == 7.5M, "invalid rating input cannot change the active filter");
            Assert(rating.AccessibilityObject.Role == AccessibleRole.SpinButton, "custom rating input exposes a spin-button role");
        }
        using (var check = (CheckBox)Create("ThemedCheckBox"))
        {
            check.Text = "Saved shows"; check.Checked = true;
            Assert(check.Checked && check.AccessibilityObject.Role == AccessibleRole.CheckButton, "themed checkbox retains checked state and accessibility");
        }
        using (var grid = (DataGridView)Create("ThemedDataGridView"))
        using (var host = (Control)Create("ThemedGridHost", grid))
        {
            grid.VirtualMode = true; grid.AllowUserToAddRows = false; grid.Columns.Add("Date", "DATE"); grid.Columns[0].Width = 600; grid.RowCount = 100;
            host.Size = new Size(320, 200); host.PerformLayout();
            Assert(grid.VirtualMode && grid.RowCount == 100, "custom scroll host preserves virtual result rows");
            Assert(grid.ScrollBars == ScrollBars.None, "results table does not draw native Windows scrollbars");
            Assert(Walk(host).Count(control => control.GetType().Name == "ThemedScrollBar") == 2, "results table has custom vertical and horizontal scrollbars");
            host.CreateControl(); Application.DoEvents();
            host.GetType().GetMethod("SynchronizeScrollBars").Invoke(host, null);
            var bars = Walk(host).Where(control => control.GetType().Name == "ThemedScrollBar").ToArray();
            var vertical = bars.Single(control => (Orientation)Get(control, "Orientation") == Orientation.Vertical);
            var horizontal = bars.Single(control => (Orientation)Get(control, "Orientation") == Orientation.Horizontal);
            Set(vertical, "Value", 15);
            Assert(grid.FirstDisplayedScrollingRowIndex == 15, "custom vertical scrolling moves the virtual result viewport");
            Set(horizontal, "Value", 100);
            Assert(grid.HorizontalScrollingOffset == 100, "custom horizontal scrolling reveals the remaining columns");
            grid.RowCount = 0; host.GetType().GetMethod("SynchronizeScrollBars").Invoke(host, null);
            Assert((int)Get(vertical, "Value") == 0 && (int)Get(vertical, "Maximum") == 0, "empty results reset the custom scroll range");
        }
        using (var body = new Panel { Size = new Size(200, 1000) })
        using (var panel = (Control)Create("ThemedScrollPanel"))
        {
            var last = new Button { Text = "Last filter", Location = new Point(0, 930) }; body.Controls.Add(last);
            Set(panel, "Content", body); panel.Size = new Size(240, 220); panel.PerformLayout();
            Assert(ReferenceEquals(Get(panel, "Content"), body), "filter scroll panel keeps its original controls");
            Assert(Walk(panel).Any(control => control.GetType().Name == "ThemedScrollBar"), "filter panel uses a custom scrollbar");
            panel.CreateControl(); Application.DoEvents();
            panel.GetType().GetMethod("ScrollControlIntoView").Invoke(panel, new object[] { last });
            Assert(body.Top < 0 && last.Bottom + body.Top <= panel.ClientSize.Height, "keyboard focus can reveal filters below the viewport");
        }
        using (var text = new RichTextBox { Text = String.Join("\n", Enumerable.Range(1, 60).Select(index => "Recording note " + index)) })
        using (var host = (Control)Create("ThemedRichTextHost", text))
        {
            host.Size = new Size(350, 200); host.PerformLayout();
            Assert(text.ScrollBars == RichTextBoxScrollBars.None && text.Text.Contains("Recording note 60"), "recording notes preserve text without native scrollbar chrome");
            Assert(Walk(host).Any(control => control.GetType().Name == "ThemedScrollBar"), "recording notes use a custom scrollbar");
            host.CreateControl(); Application.DoEvents();
            host.GetType().GetMethod("SynchronizeScrollBar").Invoke(host, null);
            var bar = Walk(host).Single(control => control.GetType().Name == "ThemedScrollBar");
            Assert((int)Get(bar, "Maximum") > 100, "wrapped recording notes expose their full scroll range");
            int originalTop = text.GetPositionFromCharIndex(0).Y;
            Set(bar, "Value", 100);
            Assert(text.GetPositionFromCharIndex(0).Y < originalTop, "custom recording-note scrolling moves the native text viewport");
        }
        using (var tabs = (Control)Create("ThemedTabs"))
        {
            var add = tabs.GetType().GetMethod("AddPage");
            add.Invoke(tabs, new object[] { "Recording sources", new Panel() }); add.Invoke(tabs, new object[] { "Setlist", new Panel() });
            Set(tabs, "SelectedIndex", 1);
            Assert(Convert.ToInt32(Get(tabs, "SelectedIndex")) == 1, "custom detail tabs switch to the requested page");
        }
    }

    static void Render(string output)
    {
        var theme = app.GetType("ToolDriveOffline.Theme", true);
        Color background = (Color)theme.GetField("Background").GetValue(null);
        Color text = (Color)theme.GetField("Text").GetValue(null);
        using (var form = new Form { ClientSize = new Size(720, 430), BackColor = background, FormBorderStyle = FormBorderStyle.None, Font = new Font("Segoe UI", 11F) })
        {
            form.Controls.Add(new Label { Text = "Tool Drive Offline · custom controls", ForeColor = text, AutoSize = true, Location = new Point(28, 24), Font = new Font("Segoe UI", 17F, FontStyle.Bold) });
            var picker = (Control)Create("ThemedDropDown"); picker.Location = new Point(28, 94); picker.Size = new Size(290, 42);
            ((IList)Get(picker, "Items")).Add("On the drive"); Set(picker, "SelectedIndex", 0); form.Controls.Add(picker);
            var rating = (Control)Create("ThemedNumberBox"); rating.Location = new Point(350, 94); rating.Size = new Size(220, 42); Set(rating, "Maximum", 10M); Set(rating, "DecimalPlaces", 1); Set(rating, "Increment", 0.5M); Set(rating, "Value", 8.5M); form.Controls.Add(rating);
            var check = (CheckBox)Create("ThemedCheckBox"); check.Location = new Point(28, 166); check.Size = new Size(250, 32); check.Text = "Saved shows"; check.Checked = true; form.Controls.Add(check);
            var vertical = (Control)Create("ThemedScrollBar"); vertical.Location = new Point(660, 94); vertical.Size = new Size(18, 250); Set(vertical, "Maximum", 100); Set(vertical, "LargeChange", 20); Set(vertical, "Value", 35); form.Controls.Add(vertical);
            var horizontal = (Control)Create("ThemedScrollBar"); horizontal.Location = new Point(28, 344); horizontal.Size = new Size(550, 18); Set(horizontal, "Orientation", Orientation.Horizontal); Set(horizontal, "Maximum", 100); Set(horizontal, "LargeChange", 30); Set(horizontal, "Value", 25); form.Controls.Add(horizontal);
            SaveControl(form, output);
        }
    }

    static void SaveControl(Control control, string output)
    {
        var form = control as Form;
        if (form != null)
        {
            // Detach the content into a visible standalone control without showing a window
            // or raising the application's Shown event and its automatic update checks.
            var children = form.Controls.Cast<Control>().ToArray();
            using (var surface = new Panel { Size = form.ClientSize, BackColor = form.BackColor, Font = form.Font })
            {
                foreach (var child in children) surface.Controls.Add(child);
                SaveControl(surface, output);
                foreach (var child in children) form.Controls.Add(child);
            }
            return;
        }
        control.CreateControl(); control.PerformLayout();
        using (var bitmap = new Bitmap(control.Width, control.Height))
        {
            control.DrawToBitmap(bitmap, new Rectangle(Point.Empty, bitmap.Size));
            bitmap.Save(output, System.Drawing.Imaging.ImageFormat.Png);
        }
    }

    static void RenderApplication(string output)
    {
        object catalog = app.GetType("ToolDriveOffline.Catalog", true).GetMethod("Load").Invoke(null, null);
        using (var main = (Form)Create("MainForm", catalog, null))
        {
            main.BindingContext = new BindingContext();
            SaveControl(main, output + ".main.png");
            object selected = main.GetType().GetMethod("Selected", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(main, null);
            object show = Get(selected, "Show");
            object saved = main.GetType().GetField("saved", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(main);
            object options = main.GetType().GetMethod("Options", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(main, null);
            using (var details = (Form)Create("DetailForm", catalog, show, options, saved, null)) SaveControl(details, output + ".details.png");
            var picker = Walk(main).Single(control => control.AccessibleName == "From year");
            picker.GetType().GetMethod("EnsurePopup", BindingFlags.Instance | BindingFlags.NonPublic).Invoke(picker, null);
            var popup = (Control)picker.GetType().GetField("viewport", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(picker);
            popup.Size = new Size(240, 350);
            SaveControl(popup, output + ".dropdown.png");
        }
    }

    [STAThread]
    public static int Main(string[] args)
    {
        try
        {
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            app = Assembly.LoadFrom(Path.GetFullPath(args[0]));
            if (args.Length > 2 && args[1] == "--render") { Render(Path.GetFullPath(args[2])); RenderApplication(Path.GetFullPath(args[2])); }
            else { Checks(); Console.WriteLine("PASS " + passed + " themed-control interaction assertions; no app startup or profile writes."); }
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
}
