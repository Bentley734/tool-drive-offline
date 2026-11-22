using System;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ToolDriveOffline
{
    // The host owns scrolling; DataGridView still owns selection and keyboard navigation.
    public sealed class ThemedDataGridView : DataGridView
    {
        public event MouseEventHandler ScrollRequested;
        public event MouseEventHandler HorizontalScrollRequested;
        protected override void OnMouseWheel(MouseEventArgs e)
        {
            MouseEventHandler handler = ScrollRequested;
            if (handler == null) { base.OnMouseWheel(e); return; }
            handler(this, e);
            HandledMouseEventArgs handled = e as HandledMouseEventArgs;
            if (handled != null) handled.Handled = true;
        }
        protected override void WndProc(ref Message message)
        {
            if (message.Msg == 0x020E && HorizontalScrollRequested != null)
            {
                int delta = (short)((message.WParam.ToInt64() >> 16) & 0xffff);
                HorizontalScrollRequested(this, new MouseEventArgs(MouseButtons.None, 0, 0, 0, delta));
                message.Result = IntPtr.Zero; return;
            }
            base.WndProc(ref message);
        }
    }

    public sealed class ThemedGridHost : UserControl
    {
        private readonly DataGridView grid;
        private readonly ThemedScrollBar vertical = new ThemedScrollBar { Orientation = Orientation.Vertical };
        private readonly ThemedScrollBar horizontal = new ThemedScrollBar { Orientation = Orientation.Horizontal };
        private readonly WheelWindow wheelWindow;
        private bool syncing, pending;
        private int verticalRemainder, horizontalRemainder;

        public ThemedGridHost(DataGridView grid)
        {
            if (grid == null) throw new ArgumentNullException("grid");
            this.grid = grid;
            BackColor = Theme.Panel; Margin = new Padding(0); TabStop = false;
            TableLayoutPanel layout = ScrollChrome.GridLayout();
            Controls.Add(layout);
            grid.ScrollBars = ScrollBars.None; grid.Dock = DockStyle.Fill; grid.Margin = new Padding(0);
            vertical.Dock = DockStyle.Fill; vertical.Margin = new Padding(0); vertical.AccessibleName = "Show list vertical scroll";
            horizontal.Dock = DockStyle.Fill; horizontal.Margin = new Padding(0); horizontal.AccessibleName = "Show list horizontal scroll";
            layout.Controls.Add(grid, 0, 0); layout.Controls.Add(vertical, 1, 0); layout.Controls.Add(horizontal, 0, 1);
            layout.Controls.Add(new Panel { BackColor = Theme.Panel, Dock = DockStyle.Fill, Margin = new Padding(0) }, 1, 1);
            vertical.ValueChanged += delegate { SetVertical(); };
            horizontal.ValueChanged += delegate { SetHorizontal(); };
            grid.Scroll += delegate { RequestSync(); };
            grid.RowsAdded += delegate { RequestSync(); };
            grid.RowsRemoved += delegate { RequestSync(); };
            grid.ColumnWidthChanged += delegate { RequestSync(); };
            grid.ColumnStateChanged += delegate { RequestSync(); };
            grid.ColumnAdded += delegate { RequestSync(); };
            grid.ColumnRemoved += delegate { RequestSync(); };
            grid.ColumnDisplayIndexChanged += delegate { RequestSync(); };
            grid.SizeChanged += delegate { RequestSync(); };
            grid.ColumnHeadersHeightChanged += delegate { RequestSync(); };
            grid.RowHeadersWidthChanged += delegate { RequestSync(); };
            grid.HandleCreated += delegate { RequestSync(); };
            grid.KeyUp += delegate { RequestSync(); };
            ThemedDataGridView themed = grid as ThemedDataGridView;
            if (themed != null)
            {
                themed.ScrollRequested += delegate(object sender, MouseEventArgs e) { Wheel(e.Delta, (ModifierKeys & Keys.Shift) != 0, false); };
                themed.HorizontalScrollRequested += delegate(object sender, MouseEventArgs e) { Wheel(e.Delta, true, true); };
            }
            else wheelWindow = new WheelWindow(grid, Wheel);
        }

        public void SynchronizeScrollBars() { Sync(); }

        private void RequestSync()
        {
            if (syncing || pending || IsDisposed || Disposing) return;
            if (!IsHandleCreated) { Sync(); return; }
            pending = true;
            try { BeginInvoke(new Action(delegate { pending = false; if (!IsDisposed && !Disposing) Sync(); })); }
            catch (InvalidOperationException) { pending = false; }
        }
        private void Sync()
        {
            if (syncing || IsDisposed || grid.IsDisposed) return;
            syncing = true;
            try
            {
                int header = grid.ColumnHeadersVisible ? grid.ColumnHeadersHeight : 0;
                int viewportHeight = Math.Max(0, grid.ClientSize.Height - header);
                int rowHeight = Math.Max(1, grid.RowTemplate.Height);
                int visibleRows = Math.Max(1, viewportHeight / rowHeight);
                vertical.SetRange(Math.Max(0, grid.RowCount - visibleRows), visibleRows);
                vertical.SmallChange = 1;
                int first = grid.RowCount == 0 ? 0 : Math.Max(0, grid.FirstDisplayedScrollingRowIndex);
                if (grid.IsHandleCreated && grid.RowCount > 0 && first > vertical.Maximum)
                {
                    try { grid.FirstDisplayedScrollingRowIndex = vertical.Maximum; first = Math.Max(0, grid.FirstDisplayedScrollingRowIndex); }
                    catch (InvalidOperationException) { }
                }
                vertical.Value = first;
                long totalWidth = 0;
                foreach (DataGridViewColumn column in grid.Columns) if (column.Visible) totalWidth += column.Width;
                int viewportWidth = Math.Max(0, grid.ClientSize.Width - (grid.RowHeadersVisible ? grid.RowHeadersWidth : 0));
                horizontal.SetRange((int)Math.Min(Int32.MaxValue, Math.Max(0L, totalWidth - viewportWidth)), Math.Max(1, viewportWidth));
                horizontal.SmallChange = Math.Max(16, Font.Height * 2);
                horizontal.Value = grid.HorizontalScrollingOffset;
            }
            catch (InvalidOperationException) { }
            finally { syncing = false; }
        }
        private void SetVertical()
        {
            if (syncing || grid.IsDisposed || grid.RowCount == 0) return;
            try { grid.FirstDisplayedScrollingRowIndex = Math.Max(0, Math.Min(grid.RowCount - 1, vertical.Value)); }
            catch (InvalidOperationException) { }
            catch (ArgumentOutOfRangeException) { }
            RequestSync();
        }
        private void SetHorizontal()
        {
            if (syncing || grid.IsDisposed) return;
            try { grid.HorizontalScrollingOffset = Math.Max(0, horizontal.Value); }
            catch (InvalidOperationException) { }
            catch (ArgumentOutOfRangeException) { }
            RequestSync();
        }
        private void Wheel(int delta, bool sideways, bool nativeHorizontal)
        {
            if (sideways)
            {
                horizontalRemainder += delta;
                int ticks = horizontalRemainder / 120; horizontalRemainder %= 120;
                horizontal.ScrollBy(ticks * horizontal.SmallChange * (nativeHorizontal ? 1 : -1));
            }
            else
            {
                verticalRemainder += delta;
                int ticks = verticalRemainder / 120; verticalRemainder %= 120;
                int lines = SystemInformation.MouseWheelScrollLines;
                if (lines == 0) return;
                vertical.ScrollBy(-ticks * (lines < 0 ? Math.Max(1, vertical.LargeChange) : Math.Max(1, lines)));
            }
        }
        protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); RequestSync(); }
        protected override void OnVisibleChanged(EventArgs e) { base.OnVisibleChanged(e); RequestSync(); }
        protected override void Dispose(bool disposing) { if (disposing && wheelWindow != null) wheelWindow.Dispose(); base.Dispose(disposing); }
    }

    // A clipped content panel, rather than AutoScroll, avoids native light scroll bars.
    public sealed class ThemedScrollPanel : UserControl
    {
        private readonly Panel viewport = new Panel { Dock = DockStyle.Fill, Margin = new Padding(0) };
        private readonly ThemedScrollBar vertical = new ThemedScrollBar { Orientation = Orientation.Vertical, Dock = DockStyle.Fill, Margin = new Padding(0) };
        private Control content;
        private bool syncing, pending;
        private int wheelRemainder;
        private Size originalMinimum, originalMaximum;

        public ThemedScrollPanel()
        {
            BackColor = Theme.Panel; viewport.BackColor = Theme.Panel; TabStop = false;
            TableLayoutPanel layout = ScrollChrome.VerticalLayout(); Controls.Add(layout);
            layout.Controls.Add(viewport, 0, 0); layout.Controls.Add(vertical, 1, 0);
            vertical.AccessibleName = "Filter panel vertical scroll";
            vertical.ValueChanged += delegate { if (content != null) content.Top = -vertical.Value; };
            viewport.SizeChanged += delegate { RequestLayout(); };
            viewport.MouseWheel += ContentWheel;
        }
        public Control Content
        {
            get { return content; }
            set
            {
                if (content == value) return;
                if (content != null)
                {
                    Hook(content, false); viewport.Controls.Remove(content);
                    content.MinimumSize = originalMinimum; content.MaximumSize = originalMaximum;
                }
                content = value;
                if (content != null)
                {
                    originalMinimum = content.MinimumSize; originalMaximum = content.MaximumSize;
                    content.Dock = DockStyle.None; content.Margin = new Padding(0); content.Location = Point.Empty;
                    viewport.Controls.Add(content); Hook(content, true);
                }
                RequestLayout();
            }
        }
        public new void ScrollControlIntoView(Control control) { EnsureVisible(control); }
        private void Hook(Control control, bool attach)
        {
            bool input = OwnsInputWheel(control);
            if (attach)
            {
                control.Enter += ContentEnter; control.Layout += ContentLayout;
                if (!input)
                {
                    control.ControlAdded += ChildAdded; control.ControlRemoved += ChildRemoved;
                    control.MouseWheel += ContentWheel;
                }
            }
            else
            {
                control.Enter -= ContentEnter; control.Layout -= ContentLayout;
                control.ControlAdded -= ChildAdded; control.ControlRemoved -= ChildRemoved;
                control.MouseWheel -= ContentWheel;
            }
            if (!input) foreach (Control child in control.Controls) Hook(child, attach);
        }
        private static bool OwnsInputWheel(Control control)
        {
            return control is ComboBox || control is UpDownBase || control.AccessibleRole == AccessibleRole.ComboBox || control.AccessibleRole == AccessibleRole.SpinButton;
        }
        private static bool FocusedInput(Control root)
        {
            if (OwnsInputWheel(root)) return root.ContainsFocus;
            foreach (Control child in root.Controls) if (child.ContainsFocus && FocusedInput(child)) return true;
            return false;
        }
        private void ChildAdded(object sender, ControlEventArgs e) { Hook(e.Control, true); RequestLayout(); }
        private void ChildRemoved(object sender, ControlEventArgs e) { Hook(e.Control, false); RequestLayout(); }
        private void ContentLayout(object sender, LayoutEventArgs e) { RequestLayout(); }
        private void ContentEnter(object sender, EventArgs e) { EnsureVisible(sender as Control); }
        private void RequestLayout()
        {
            if (syncing || pending || IsDisposed || Disposing) return;
            if (!IsHandleCreated) { UpdateContent(); return; }
            pending = true;
            try { BeginInvoke(new Action(delegate { pending = false; if (!IsDisposed && !Disposing) UpdateContent(); })); }
            catch (InvalidOperationException) { pending = false; }
        }
        private void UpdateContent()
        {
            if (syncing || content == null || content.IsDisposed) return;
            syncing = true;
            try
            {
                int width = Math.Max(1, viewport.ClientSize.Width);
                content.MinimumSize = new Size(width, 0); content.MaximumSize = new Size(width, 0);
                content.Width = width;
                Size preferred = content.GetPreferredSize(new Size(width, 0));
                int height = Math.Max(1, preferred.Height);
                content.Size = new Size(width, height);
                int viewportHeight = Math.Max(1, viewport.ClientSize.Height);
                vertical.SetRange(Math.Max(0, height - viewportHeight), viewportHeight);
                vertical.SmallChange = Math.Max(16, Font.Height * 3);
                content.Location = new Point(0, -vertical.Value);
            }
            finally { syncing = false; }
        }
        private void EnsureVisible(Control target)
        {
            if (target == null || content == null || !content.Contains(target)) return;
            Rectangle rectangle = target.Bounds;
            Control ancestor = target.Parent;
            while (ancestor != null && ancestor != content) { rectangle.Offset(ancestor.Left, ancestor.Top); ancestor = ancestor.Parent; }
            int top = vertical.Value, height = Math.Max(1, viewport.ClientSize.Height);
            if (rectangle.Top < top) vertical.Value = Math.Max(0, rectangle.Top - 4);
            else if (rectangle.Bottom > top + height) vertical.Value = rectangle.Bottom - height + 4;
        }
        private void ContentWheel(object sender, MouseEventArgs e)
        {
            HandledMouseEventArgs handled = e as HandledMouseEventArgs;
            if (handled != null && handled.Handled) return;
            // Custom combo/number controls own their focused wheel gestures. Their native
            // child messages may bubble to this panel after changing a selection/value.
            if (content != null && FocusedInput(content)) { if (handled != null) handled.Handled = true; return; }
            wheelRemainder += e.Delta; int ticks = wheelRemainder / 120; wheelRemainder %= 120;
            int lines = SystemInformation.MouseWheelScrollLines;
            if (lines == 0) return;
            vertical.ScrollBy(-ticks * (lines < 0 ? Math.Max(1, vertical.LargeChange) : Math.Max(1, lines) * Math.Max(1, Font.Height)));
            if (handled != null) handled.Handled = true;
        }
        protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); RequestLayout(); }
        protected override void OnVisibleChanged(EventArgs e) { base.OnVisibleChanged(e); RequestLayout(); }
        protected override void Dispose(bool disposing) { if (disposing && content != null) Hook(content, false); base.Dispose(disposing); }
    }

    public sealed class ThemedRichTextHost : UserControl
    {
        private readonly RichTextBox box;
        private readonly ThemedScrollBar vertical = new ThemedScrollBar { Orientation = Orientation.Vertical, Dock = DockStyle.Fill, Margin = new Padding(0) };
        private readonly RichTextWindow nativeWindow;
        private bool syncing, pending;
        private int wheelRemainder;

        public ThemedRichTextHost(RichTextBox box)
        {
            if (box == null) throw new ArgumentNullException("box");
            this.box = box;
            BackColor = Theme.Panel; Margin = new Padding(0); TabStop = false;
            TableLayoutPanel layout = ScrollChrome.VerticalLayout(); Controls.Add(layout);
            box.ScrollBars = RichTextBoxScrollBars.None; box.DetectUrls = false; box.Dock = DockStyle.Fill; box.Margin = new Padding(0);
            vertical.AccessibleName = "Recording notes vertical scroll";
            layout.Controls.Add(box, 0, 0); layout.Controls.Add(vertical, 1, 0);
            vertical.ValueChanged += delegate { ScrollTo(vertical.Value); };
            box.TextChanged += delegate { RequestSync(); };
            box.VScroll += delegate { RequestSync(); };
            box.SelectionChanged += delegate { RequestSync(); };
            box.SizeChanged += delegate { RequestSync(); };
            box.FontChanged += delegate { RequestSync(); };
            box.HandleCreated += delegate { RequestSync(); };
            nativeWindow = new RichTextWindow(box, Wheel, RequestSync);
        }
        public void SynchronizeScrollBar() { Sync(); }
        private void RequestSync()
        {
            if (syncing || pending || IsDisposed || Disposing || box.IsDisposed || !box.IsHandleCreated) return;
            pending = true;
            try { box.BeginInvoke(new Action(delegate { pending = false; if (!IsDisposed && !Disposing) Sync(); })); }
            catch (InvalidOperationException) { pending = false; }
        }
        private void Sync()
        {
            if (syncing || box.IsDisposed || !box.IsHandleCreated) return;
            syncing = true;
            try
            {
                Point position = NativeScroll.GetRichPosition(box.Handle);
                int viewport = Math.Max(1, box.ClientSize.Height);
                int maximum = 0;
                NativeScroll.ScrollInfo info;
                if (NativeScroll.TryVerticalInfo(box.Handle, out info) && info.Page > 0 && info.Maximum > 0)
                    maximum = Math.Max(0, info.Maximum - (int)info.Page + 1);
                else if (box.TextLength > 0)
                {
                    Point last = box.GetPositionFromCharIndex(Math.Max(0, box.TextLength - 1));
                    int contentHeight = Math.Max(0, last.Y + position.Y) + Math.Max(2, box.Font.Height * 2) + 4;
                    maximum = Math.Max(0, contentHeight - viewport);
                }
                vertical.SetRange(maximum, viewport);
                vertical.SmallChange = Math.Max(16, box.Font.Height * 3);
                vertical.Value = Math.Max(0, position.Y);
            }
            finally { syncing = false; }
        }
        private void ScrollTo(int value)
        {
            if (syncing || box.IsDisposed || !box.IsHandleCreated) return;
            Point point = NativeScroll.GetRichPosition(box.Handle); point.Y = Math.Max(0, value);
            NativeScroll.SetRichPosition(box.Handle, point); RequestSync();
        }
        private void Wheel(int delta)
        {
            Sync(); wheelRemainder += delta; int ticks = wheelRemainder / 120; wheelRemainder %= 120;
            int lines = SystemInformation.MouseWheelScrollLines;
            if (lines == 0) return;
            vertical.ScrollBy(-ticks * (lines < 0 ? Math.Max(1, vertical.LargeChange) : Math.Max(1, lines) * Math.Max(1, box.Font.Height)));
        }
        protected override void OnVisibleChanged(EventArgs e) { base.OnVisibleChanged(e); RequestSync(); }
        protected override void Dispose(bool disposing) { if (disposing && nativeWindow != null) nativeWindow.Dispose(); base.Dispose(disposing); }

        private sealed class RichTextWindow : NativeWindow, IDisposable
        {
            private readonly RichTextBox owner;
            private readonly Action<int> wheel;
            private readonly Action changed;
            public RichTextWindow(RichTextBox owner, Action<int> wheel, Action changed)
            {
                this.owner = owner; this.wheel = wheel; this.changed = changed;
                owner.HandleCreated += Created; owner.HandleDestroyed += Destroyed;
                if (owner.IsHandleCreated) AssignHandle(owner.Handle);
            }
            private void Created(object sender, EventArgs e) { AssignHandle(owner.Handle); changed(); }
            private void Destroyed(object sender, EventArgs e) { ReleaseHandle(); }
            protected override void WndProc(ref Message message)
            {
                if (message.Msg == 0x020A) { wheel((short)((message.WParam.ToInt64() >> 16) & 0xffff)); message.Result = IntPtr.Zero; return; }
                base.WndProc(ref message);
                if (message.Msg == 0x0115 || message.Msg == 0x0101 || message.Msg == 0x0202 || message.Msg == 0x0005 || message.Msg == 0x00B7) changed();
            }
            public void Dispose() { owner.HandleCreated -= Created; owner.HandleDestroyed -= Destroyed; ReleaseHandle(); }
        }
    }

    public sealed class ThemedTabs : UserControl
    {
        private readonly List<Control> pages = new List<Control>();
        private readonly List<string> titles = new List<string>();
        private readonly Panel body = new Panel { Dock = DockStyle.Fill, Margin = new Padding(0), TabStop = false };
        private readonly TabStrip strip;
        private int selectedIndex = -1;
        public event EventHandler SelectedIndexChanged;
        public ThemedTabs()
        {
            BackColor = Theme.Panel; Font = Theme.Body; Margin = new Padding(0); TabStop = false;
            strip = new TabStrip(this) { Dock = DockStyle.Top, Height = 42, TabIndex = 0 };
            body.TabIndex = 1; body.BackColor = Theme.Panel; Controls.Add(body); Controls.Add(strip);
        }
        public int SelectedIndex
        {
            get { return selectedIndex; }
            set
            {
                if (value < 0 || value >= pages.Count) throw new ArgumentOutOfRangeException("value");
                if (selectedIndex == value) return;
                selectedIndex = value;
                for (int i = 0; i < pages.Count; i++) pages[i].Visible = i == selectedIndex;
                pages[value].BringToFront(); strip.AccessibleName = "Recording detail sections. Selected: " + titles[value]; strip.Invalidate();
                EventHandler handler = SelectedIndexChanged; if (handler != null) handler(this, EventArgs.Empty);
            }
        }
        public void AddPage(string title, Control content)
        {
            if (content == null) throw new ArgumentNullException("content");
            titles.Add(title ?? ""); pages.Add(content);
            content.Dock = DockStyle.Fill; content.Margin = new Padding(0); content.Visible = false; body.Controls.Add(content);
            if (selectedIndex < 0) SelectedIndex = 0;
            strip.Invalidate();
        }
        private void MoveTab(int offset) { if (pages.Count > 0) SelectedIndex = (selectedIndex + pages.Count + offset) % pages.Count; }
        protected override bool ProcessCmdKey(ref Message message, Keys keyData)
        {
            if (keyData == (Keys.Control | Keys.Tab)) { MoveTab(1); return true; }
            if (keyData == (Keys.Control | Keys.Shift | Keys.Tab)) { MoveTab(-1); return true; }
            return base.ProcessCmdKey(ref message, keyData);
        }
        private sealed class TabStrip : Control
        {
            private readonly ThemedTabs owner;
            public TabStrip(ThemedTabs owner)
            {
                this.owner = owner; SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.Selectable, true);
                TabStop = true; AccessibleRole = AccessibleRole.PageTabList; BackColor = Theme.Raised; ForeColor = Theme.Muted;
            }
            private List<Rectangle> Rectangles()
            {
                List<Rectangle> result = new List<Rectangle>(); int left = 0;
                foreach (string title in owner.titles)
                {
                    int width = Math.Max(100, TextRenderer.MeasureText(title, owner.Font).Width + 32);
                    result.Add(new Rectangle(left, 0, width, Height)); left += width;
                }
                return result;
            }
            protected override void OnPaint(PaintEventArgs e)
            {
                e.Graphics.Clear(Theme.Raised);
                List<Rectangle> rectangles = Rectangles();
                for (int i = 0; i < rectangles.Count; i++)
                {
                    Rectangle rectangle = rectangles[i]; bool active = i == owner.selectedIndex;
                    using (Brush brush = new SolidBrush(active ? Theme.Panel : Theme.Raised)) e.Graphics.FillRectangle(brush, rectangle);
                    Rectangle text = rectangle; text.Inflate(-12, -3);
                    TextRenderer.DrawText(e.Graphics, owner.titles[i], owner.Font, text, active ? Theme.Amber : Theme.Muted, TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
                    if (active) using (Brush brush = new SolidBrush(Theme.Amber)) e.Graphics.FillRectangle(brush, rectangle.Left, rectangle.Bottom - 3, rectangle.Width, 3);
                    if (active && Focused) { Rectangle focus = rectangle; focus.Inflate(-5, -5); ControlPaint.DrawFocusRectangle(e.Graphics, focus, Theme.Amber, Theme.Panel); }
                }
                using (Pen pen = new Pen(Theme.Line)) e.Graphics.DrawLine(pen, 0, Math.Max(0, Height - 1), Width, Math.Max(0, Height - 1));
            }
            protected override void OnMouseDown(MouseEventArgs e)
            {
                base.OnMouseDown(e); Focus(); List<Rectangle> rectangles = Rectangles();
                for (int i = 0; i < rectangles.Count; i++) if (rectangles[i].Contains(e.Location)) { owner.SelectedIndex = i; break; }
            }
            protected override bool IsInputKey(Keys keyData)
            {
                Keys key = keyData & Keys.KeyCode;
                return key == Keys.Left || key == Keys.Right || key == Keys.Home || key == Keys.End || base.IsInputKey(keyData);
            }
            protected override void OnKeyDown(KeyEventArgs e)
            {
                if (e.KeyCode == Keys.Left) { owner.MoveTab(-1); e.Handled = true; }
                else if (e.KeyCode == Keys.Right) { owner.MoveTab(1); e.Handled = true; }
                else if (e.KeyCode == Keys.Home && owner.pages.Count > 0) { owner.SelectedIndex = 0; e.Handled = true; }
                else if (e.KeyCode == Keys.End && owner.pages.Count > 0) { owner.SelectedIndex = owner.pages.Count - 1; e.Handled = true; }
                base.OnKeyDown(e);
            }
            protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
            protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
        }
    }

    internal static class ScrollChrome
    {
        public static TableLayoutPanel VerticalLayout()
        {
            TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, Margin = new Padding(0), Padding = new Padding(0), BackColor = Theme.Panel, TabStop = false };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 16));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); return layout;
        }
        public static TableLayoutPanel GridLayout()
        {
            TableLayoutPanel layout = VerticalLayout(); layout.RowCount = 2;
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 16)); return layout;
        }
    }

    internal sealed class WheelWindow : NativeWindow, IDisposable
    {
        private readonly Control owner;
        private readonly Action<int, bool, bool> wheel;
        public WheelWindow(Control owner, Action<int, bool, bool> wheel)
        {
            this.owner = owner; this.wheel = wheel; owner.HandleCreated += Created; owner.HandleDestroyed += Destroyed;
            if (owner.IsHandleCreated) AssignHandle(owner.Handle);
        }
        private void Created(object sender, EventArgs e) { AssignHandle(owner.Handle); }
        private void Destroyed(object sender, EventArgs e) { ReleaseHandle(); }
        protected override void WndProc(ref Message message)
        {
            if (message.Msg == 0x020A || message.Msg == 0x020E)
            {
                bool nativeHorizontal = message.Msg == 0x020E;
                wheel((short)((message.WParam.ToInt64() >> 16) & 0xffff), nativeHorizontal || (Control.ModifierKeys & Keys.Shift) != 0, nativeHorizontal);
                message.Result = IntPtr.Zero; return;
            }
            base.WndProc(ref message);
        }
        public void Dispose() { owner.HandleCreated -= Created; owner.HandleDestroyed -= Destroyed; ReleaseHandle(); }
    }

    internal static class NativeScroll
    {
        private const int GetScrollPosition = 0x0400 + 221, SetScrollPosition = 0x0400 + 222;
        [StructLayout(LayoutKind.Sequential)]
        internal struct ScrollInfo { public uint Size, Mask; public int Minimum, Maximum; public uint Page; public int Position, TrackPosition; }
        [DllImport("user32.dll", EntryPoint = "SendMessageW")]
        private static extern IntPtr SendPoint(IntPtr window, int message, IntPtr wParam, ref Point point);
        [DllImport("user32.dll")]
        private static extern bool GetScrollInfo(IntPtr window, int bar, ref ScrollInfo info);
        public static Point GetRichPosition(IntPtr window) { Point point = Point.Empty; SendPoint(window, GetScrollPosition, IntPtr.Zero, ref point); return point; }
        public static void SetRichPosition(IntPtr window, Point point) { SendPoint(window, SetScrollPosition, IntPtr.Zero, ref point); }
        public static bool TryVerticalInfo(IntPtr window, out ScrollInfo info)
        {
            info = new ScrollInfo { Size = (uint)Marshal.SizeOf(typeof(ScrollInfo)), Mask = 0x0001 | 0x0002 | 0x0004 };
            return GetScrollInfo(window, 1, ref info);
        }
    }
}
