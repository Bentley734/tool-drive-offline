using System;
using System.Drawing;
using System.Reflection;
using System.Windows.Forms;

// Reflection-only control checks; never shows a form or accesses profile/network data.
public static class ScrollBarChecks
{
    private static int assertions;
    private static Type type;
    private static object bar;
    private static void Assert(bool condition, string message) { if (!condition) throw new Exception(message); assertions++; }
    private static object Get(string name) { return type.GetProperty(name).GetValue(bar, null); }
    private static int Number(string name) { return (int)Get(name); }
    private static void Set(string name, object value) { type.GetProperty(name).SetValue(bar, value, null); }
    private static void Call(string name, params object[] values) { type.GetMethod(name, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic).Invoke(bar, values); }
    private static Rectangle Thumb { get { return (Rectangle)Get("ThumbBounds"); } }
    private static void Key(Keys key) { KeyEventArgs e = new KeyEventArgs(key); Call("OnKeyDown", e); Assert(e.Handled && e.SuppressKeyPress, "Scroll key was not consumed: " + key); }

    [STAThread]
    public static int Main(string[] args)
    {
        try
        {
            if (args.Length != 1) throw new ArgumentException("Pass the app assembly path.");
            type = Assembly.LoadFrom(System.IO.Path.GetFullPath(args[0])).GetType("ToolDriveOffline.ThemedScrollBar", true);
            bar = Activator.CreateInstance(type);
            Assert(Number("Minimum") == 0 && Number("Maximum") == 0 && Number("Value") == 0, "Default range must be zero.");
            Assert((bool)Get("TabStop"), "The scroll bar must be keyboard focusable.");
            Set("Size", new Size(18, 240));
            int events = 0; EventHandler changed = delegate { events++; };
            type.GetEvent("ValueChanged").AddEventHandler(bar, changed);
            Call("SetRange", 900, 100);
            Rectangle start = Thumb;
            Assert(start.Width > 0 && start.Height >= 24 && start.Top >= 0, "Vertical thumb geometry was invalid.");
            Set("Value", 450); Rectangle middle = Thumb;
            Assert(events == 1 && middle.Top > start.Top, "Middle position or change event was invalid.");
            Set("Value", 450); Assert(events == 1, "Setting the same value should not raise a change event.");
            Set("Value", Int32.MaxValue); Rectangle end = Thumb;
            Assert(Number("Value") == 900 && end.Bottom <= 240 && end.Top > middle.Top, "Maximum scroll offset was not reachable.");
            Set("Value", Int32.MinValue); Assert(Number("Value") == 0 && Thumb == start, "Negative values must clamp to the start.");
            Call("ScrollBy", Int32.MaxValue); Assert(Number("Value") == 900, "ScrollBy positive overflow did not clamp.");
            Call("ScrollBy", Int32.MinValue); Assert(Number("Value") == 0, "ScrollBy negative overflow did not clamp.");
            Set("SmallChange", 7); Key(Keys.Down); Assert(Number("Value") == 7, "Down key should scroll one small increment.");
            Key(Keys.Right); Assert(Number("Value") == 14, "Right key should scroll one small increment.");
            Key(Keys.PageDown); Assert(Number("Value") == 114, "PageDown should scroll one viewport.");
            Key(Keys.PageUp); Assert(Number("Value") == 14, "PageUp should scroll one viewport.");
            Key(Keys.Up); Key(Keys.Left); Assert(Number("Value") == 0, "Up and Left should scroll backward.");
            Key(Keys.End); Assert(Number("Value") == 900, "End key should reach the exact maximum.");
            Key(Keys.Home); Assert(Number("Value") == 0, "Home key should reach the exact minimum.");

            Set("Orientation", Orientation.Horizontal); Set("Size", new Size(300, 18));
            start = Thumb; Set("Value", 900); end = Thumb;
            Assert(start.Width >= 24 && end.Left > start.Left && end.Right <= 300 && end.Top == start.Top, "Horizontal thumb geometry was invalid.");
            Set("Minimum", Int32.MinValue); Set("Maximum", Int32.MaxValue); Set("Value", Int32.MaxValue);
            Assert(Thumb.Right <= 300 && Thumb.Width >= 24, "The full integer range overflowed thumb geometry.");
            Call("ScrollBy", Int32.MinValue); Assert(Number("Value") == -1, "Large negative delta did not use saturating long arithmetic.");
            Call("ScrollBy", Int32.MinValue); Assert(Number("Value") == Int32.MinValue, "Repeated negative deltas should clamp at minimum.");
            Set("Value", 0); Set("Maximum", -50); Assert(Number("Value") == -50, "Shrinking the maximum should clamp the value.");
            Set("Minimum", 80); Assert(Number("Maximum") == 80 && Number("Value") == 80, "Minimum should normalize an inverted range.");
            Set("LargeChange", 0); Set("SmallChange", -1); Assert(Number("LargeChange") == 1 && Number("SmallChange") == 1, "Viewport and step must stay positive.");
            Set("Visible", false); Call("SetRange", -1, 0);
            Assert(Number("Minimum") == 0 && Number("Maximum") == 0 && Number("Value") == 0 && Number("LargeChange") == 1 && !(bool)Get("Visible"), "SetRange must normalize offsets without changing host-owned visibility.");
            Set("Size", Size.Empty); Assert(Thumb.IsEmpty, "A zero-size scroll bar must have empty geometry.");
            Set("Size", new Size(1, 1)); Assert(Thumb.IsEmpty, "A tiny scroll bar must have safe empty geometry.");
            Set("Size", new Size(90, 18)); Call("SetRange", 0, 100); start = Thumb;
            Assert(start.Width > 0 && start.Height > 0 && start.Right <= 90, "A zero-range thumb must fit its track.");
            AccessibleObject accessible = (AccessibleObject)Get("AccessibilityObject");
            Assert(accessible.Role == AccessibleRole.ScrollBar && !String.IsNullOrEmpty(accessible.Name) && accessible.Value == "0", "Accessible scroll bar metadata was missing.");
            Call("SetRange", 100, 10); accessible.Value = "75"; Assert(Number("Value") == 75, "Accessible value should control the offset.");
            Console.WriteLine("PASS " + assertions + " custom scroll bar assertions; no form, profile, or network access.");
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        finally { IDisposable disposable = bar as IDisposable; if (disposable != null) disposable.Dispose(); }
    }
}
