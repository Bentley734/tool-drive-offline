using System;
using System.Collections.ObjectModel;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Windows.Forms;

namespace ToolDriveOffline
{
    public sealed class DropDownItemCollection : Collection<object>
    {
        private readonly ThemedDropDown owner;
        internal DropDownItemCollection(ThemedDropDown owner) { this.owner = owner; }
        public void AddRange(object[] values)
        {
            if (values == null) throw new ArgumentNullException("values");
            foreach (object value in values) Add(value);
        }
        protected override void InsertItem(int index, object item)
        {
            base.InsertItem(index, item); owner.ItemsChanged(index, 1, false);
        }
        protected override void RemoveItem(int index)
        {
            base.RemoveItem(index); owner.ItemsChanged(index, -1, false);
        }
        protected override void SetItem(int index, object item)
        {
            base.SetItem(index, item); owner.ItemsChanged(index, 0, false);
        }
        protected override void ClearItems()
        {
            base.ClearItems(); owner.ItemsChanged(0, 0, true);
        }
    }

    public sealed class ThemedDropDown : Control
    {
        private readonly DropDownItemCollection items;
        private int selectedIndex = -1;
        private int pendingIndex = -1;
        private int dropDownHeight = 350;
        private ToolStripDropDown popup;
        private PopupViewport viewport;
        private ToolStripControlHost popupHost;
        private bool droppedDown;
        private bool restoreFocus;
        private string typedPrefix = "";
        private DateTime lastTypedUtc;
        public event EventHandler SelectedIndexChanged;

        public ThemedDropDown()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
            items = new DropDownItemCollection(this); BackColor = Theme.Panel; ForeColor = Theme.Text;
            Font = Theme.Body; Size = new Size(190, 34); MinimumSize = new Size(60, 28); TabStop = true;
            AccessibleRole = AccessibleRole.ComboBox;
        }
        public DropDownItemCollection Items { get { return items; } }
        public int SelectedIndex
        {
            get { return selectedIndex; }
            set
            {
                if (value < -1 || value >= items.Count) throw new ArgumentOutOfRangeException("value");
                if (selectedIndex == value) return;
                selectedIndex = value; if (!droppedDown) pendingIndex = value;
                base.Text = ItemText(value); Invalidate();
                AccessibilityNotifyClients(AccessibleEvents.ValueChange, -1);
                EventHandler handler = SelectedIndexChanged; if (handler != null) handler(this, EventArgs.Empty);
            }
        }
        public object SelectedItem
        {
            get { return selectedIndex < 0 || selectedIndex >= items.Count ? null : items[selectedIndex]; }
            set { SelectedIndex = value == null ? -1 : items.IndexOf(value); }
        }
        public int DropDownHeight
        {
            get { return dropDownHeight; }
            set { if (value < 1) throw new ArgumentOutOfRangeException("value"); dropDownHeight = value; }
        }
        public bool DroppedDown
        {
            get { return droppedDown; }
            set { if (value) OpenPopup(); else ClosePopup(false, true); }
        }
        internal int ScalePixels(int value) { return Math.Max(1, (int)Math.Round(value * DeviceDpi / 96.0)); }
        internal string ItemText(int index) { return index >= 0 && index < items.Count ? Convert.ToString(items[index], CultureInfo.CurrentCulture) ?? "" : ""; }

        internal void ItemsChanged(int index, int delta, bool cleared)
        {
            if (droppedDown) ClosePopup(false, false);
            int previous = selectedIndex;
            if (cleared) selectedIndex = -1;
            else if (delta > 0 && selectedIndex >= index) selectedIndex += delta;
            else if (delta < 0 && selectedIndex == index) selectedIndex = -1;
            else if (delta < 0 && selectedIndex > index) selectedIndex += delta;
            pendingIndex = selectedIndex; base.Text = ItemText(selectedIndex); Invalidate();
            if (previous != selectedIndex || (delta == 0 && selectedIndex == index))
            {
                EventHandler handler = SelectedIndexChanged; if (handler != null) handler(this, EventArgs.Empty);
                AccessibilityNotifyClients(AccessibleEvents.ValueChange, -1);
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Graphics graphics = e.Graphics; graphics.Clear(Enabled ? Theme.Panel : Theme.Background);
            Rectangle border = new Rectangle(0, 0, Math.Max(0, Width - 1), Math.Max(0, Height - 1));
            using (Pen pen = new Pen(Enabled && (Focused || droppedDown) ? Theme.Amber : Theme.Line)) graphics.DrawRectangle(pen, border);
            int inset = ScalePixels(11), chevronWidth = ScalePixels(31);
            Rectangle text = new Rectangle(inset, 1, Math.Max(0, Width - inset - chevronWidth), Math.Max(0, Height - 2));
            TextRenderer.DrawText(graphics, ItemText(selectedIndex), Font, text, Enabled ? ForeColor : Theme.Muted,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
            int cx = Width - ScalePixels(16), cy = Height / 2; int half = ScalePixels(4);
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (Pen pen = new Pen(Enabled && (Focused || droppedDown) ? Theme.Amber : Theme.Muted, Math.Max(1.3F, DeviceDpi / 72F)))
                graphics.DrawLines(pen, new Point[] { new Point(cx - half, cy - 2), new Point(cx, cy + 2), new Point(cx + half, cy - 2) });
        }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); if (!Enabled) ClosePopup(false, false); Invalidate(); }
        protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); Invalidate(); if (viewport != null) viewport.Font = Font; }
        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (Enabled && e.Button == MouseButtons.Left) { Focus(); if (droppedDown) ClosePopup(false, true); else OpenPopup(); }
        }
        protected override void OnMouseWheel(MouseEventArgs e)
        {
            base.OnMouseWheel(e);
            if (!Enabled) return;
            if (droppedDown && viewport != null) viewport.ScrollWheel(e.Delta);
            else if (Focused && items.Count > 0)
            {
                int steps = e.Delta / 120; if (steps == 0) steps = Math.Sign(e.Delta);
                SelectedIndex = Math.Max(0, Math.Min(items.Count - 1, (selectedIndex < 0 ? 0 : selectedIndex) - steps));
            }
        }
        protected override bool IsInputKey(Keys keyData)
        {
            Keys key = keyData & Keys.KeyCode;
            return key == Keys.Up || key == Keys.Down || key == Keys.Home || key == Keys.End || key == Keys.PageUp || key == Keys.PageDown || key == Keys.Enter || key == Keys.Escape || key == Keys.F4 || base.IsInputKey(keyData);
        }
        protected override void OnKeyDown(KeyEventArgs e)
        {
            base.OnKeyDown(e); HandleKey(e);
        }
        protected override void OnKeyPress(KeyPressEventArgs e)
        {
            base.OnKeyPress(e); if (!Char.IsControl(e.KeyChar)) { TypeAhead(e.KeyChar); e.Handled = true; }
        }
        protected override bool ProcessDialogKey(Keys keyData)
        {
            if ((keyData & Keys.KeyCode) == Keys.Tab && droppedDown) { ClosePopup(true, false); return base.ProcessDialogKey(keyData); }
            return base.ProcessDialogKey(keyData);
        }

        private void EnsurePopup()
        {
            if (popup != null) return;
            viewport = new PopupViewport(this); popupHost = new ToolStripControlHost(viewport);
            popupHost.AutoSize = false; popupHost.Margin = Padding.Empty; popupHost.Padding = Padding.Empty;
            popup = new ToolStripDropDown { AutoSize = false, AutoClose = true, Padding = Padding.Empty, Margin = Padding.Empty, BackColor = Theme.Panel, DropShadowEnabled = false, Renderer = new DarkPopupRenderer() };
            popup.Items.Add(popupHost);
            popup.Closed += delegate(object sender, ToolStripDropDownClosedEventArgs e)
            {
                droppedDown = false; pendingIndex = selectedIndex; typedPrefix = ""; Invalidate();
                AccessibilityNotifyClients(AccessibleEvents.StateChange, -1);
                bool focus = restoreFocus || e.CloseReason == ToolStripDropDownCloseReason.Keyboard || e.CloseReason == ToolStripDropDownCloseReason.ItemClicked;
                if (focus && !IsDisposed && !Disposing && Enabled && CanFocus) Focus(); restoreFocus = false;
            };
        }
        private void OpenPopup()
        {
            if (droppedDown || !Enabled || items.Count == 0 || IsDisposed) return;
            EnsurePopup(); pendingIndex = selectedIndex >= 0 ? selectedIndex : 0; typedPrefix = ""; restoreFocus = false;
            viewport.Font = Font; int rowHeight = viewport.RowHeight;
            int width = Math.Max(Width, ScalePixels(120));
            for (int index = 0; index < Math.Min(items.Count, 250); index++) width = Math.Max(width, TextRenderer.MeasureText(ItemText(index), Font).Width + ScalePixels(45));
            Rectangle area = Screen.FromControl(this).WorkingArea;
            width = Math.Min(width, area.Width);
            long contentHeight = (long)items.Count * rowHeight + 2;
            int height = (int)Math.Min(Math.Min(contentHeight, ScalePixels(dropDownHeight)), area.Height);
            height = Math.Max(Math.Min(area.Height, rowHeight + 2), height);
            Point position = PointToScreen(new Point(0, Height)); Point above = PointToScreen(Point.Empty);
            if (area.Bottom - position.Y < height && above.Y - area.Top > area.Bottom - position.Y) position.Y = above.Y - height;
            position.X = Math.Max(area.Left, Math.Min(area.Right - width, position.X)); position.Y = Math.Max(area.Top, Math.Min(area.Bottom - height, position.Y));
            viewport.Size = new Size(width, height); popupHost.Size = viewport.Size; popup.Size = viewport.Size;
            viewport.RefreshRange(); viewport.EnsureVisible(pendingIndex);
            droppedDown = true; popup.Show(position); viewport.Focus(); Invalidate();
            AccessibilityNotifyClients(AccessibleEvents.StateChange, -1);
        }
        private void ClosePopup(bool commit, bool focus)
        {
            if (!droppedDown) return;
            if (commit && pendingIndex >= 0 && pendingIndex < items.Count) SelectedIndex = pendingIndex;
            restoreFocus = focus;
            if (popup != null) popup.Close(ToolStripDropDownCloseReason.CloseCalled);
        }
        private void Commit(int index)
        {
            if (index < 0 || index >= items.Count || !Enabled) return;
            pendingIndex = index; SelectedIndex = index; ClosePopup(false, true);
        }
        private void SetPending(int index)
        {
            if (items.Count == 0) return;
            pendingIndex = Math.Max(0, Math.Min(items.Count - 1, index));
            if (viewport != null) { viewport.EnsureVisible(pendingIndex); viewport.Invalidate(); }
            AccessibilityNotifyClients(AccessibleEvents.Focus, pendingIndex + 1);
        }
        private void HandleKey(KeyEventArgs e)
        {
            if (!Enabled) return;
            if (e.KeyCode == Keys.F4 || (e.Alt && (e.KeyCode == Keys.Down || e.KeyCode == Keys.Up)))
            {
                if (droppedDown) ClosePopup(false, true); else OpenPopup(); e.Handled = true; e.SuppressKeyPress = true; return;
            }
            if (e.KeyCode == Keys.Escape && droppedDown) { ClosePopup(false, true); e.Handled = true; e.SuppressKeyPress = true; return; }
            if (e.KeyCode == Keys.Enter) { if (droppedDown) ClosePopup(true, true); else OpenPopup(); e.Handled = true; e.SuppressKeyPress = true; return; }
            int current = droppedDown ? pendingIndex : selectedIndex; int next = current;
            int page = viewport == null ? 8 : Math.Max(1, viewport.Height / viewport.RowHeight - 1);
            if (e.KeyCode == Keys.Up) next = current - 1;
            else if (e.KeyCode == Keys.Down) next = current + 1;
            else if (e.KeyCode == Keys.Home) next = 0;
            else if (e.KeyCode == Keys.End) next = items.Count - 1;
            else if (e.KeyCode == Keys.PageUp) next = current - page;
            else if (e.KeyCode == Keys.PageDown) next = current + page;
            else return;
            if (items.Count > 0)
            {
                next = Math.Max(0, Math.Min(items.Count - 1, next)); if (droppedDown) SetPending(next); else SelectedIndex = next;
            }
            e.Handled = true; e.SuppressKeyPress = true;
        }
        private void TypeAhead(char character)
        {
            if (!Enabled || items.Count == 0) return;
            DateTime now = DateTime.UtcNow; if ((now - lastTypedUtc).TotalMilliseconds > 900) typedPrefix = "";
            lastTypedUtc = now; typedPrefix += character;
            int current = droppedDown ? pendingIndex : selectedIndex;
            int index = FindPrefix(typedPrefix, typedPrefix.Length == 1 ? current + 1 : Math.Max(0, current));
            if (index < 0 && typedPrefix.Length > 1) { typedPrefix = character.ToString(); index = FindPrefix(typedPrefix, current + 1); }
            if (index >= 0) { if (droppedDown) SetPending(index); else SelectedIndex = index; }
        }
        private int FindPrefix(string prefix, int start)
        {
            for (int offset = 0; offset < items.Count; offset++)
            {
                int index = (Math.Max(0, start) + offset) % items.Count;
                if (CultureInfo.CurrentCulture.CompareInfo.IsPrefix(ItemText(index), prefix, CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace)) return index;
            }
            return -1;
        }
        private void PopupTab(bool backwards)
        {
            ClosePopup(true, true);
            Control container = FindForm();
            if (container == null) container = GetContainerControl() as Control;
            if (container == null) container = Parent;
            if (container != null) container.SelectNextControl(this, !backwards, true, true, true);
        }
        private bool ForwardPopupCommand(KeyEventArgs e)
        {
            if (!e.Control || e.KeyCode != Keys.F) return false;
            ClosePopup(false, true); OnKeyDown(e); return true;
        }
        protected override AccessibleObject CreateAccessibilityInstance() { return new DropDownAccessibleObject(this); }
        protected override void Dispose(bool disposing)
        {
            if (disposing && popup != null) { restoreFocus = false; popup.Dispose(); popup = null; }
            base.Dispose(disposing);
        }

        private sealed class DarkPopupRenderer : ToolStripRenderer
        {
            protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) { e.Graphics.Clear(Theme.Panel); }
            protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) { using (Pen pen = new Pen(Theme.Line)) e.Graphics.DrawRectangle(pen, 0, 0, Math.Max(0, e.ToolStrip.Width - 1), Math.Max(0, e.ToolStrip.Height - 1)); }
        }
        private sealed class PopupViewport : Control
        {
            private readonly ThemedDropDown owner;
            private readonly ThemedScrollBar scroll = new ThemedScrollBar();
            public int RowHeight { get { return Math.Max(owner.ScalePixels(29), Font.Height + owner.ScalePixels(12)); } }
            public PopupViewport(ThemedDropDown owner)
            {
                this.owner = owner; Font = owner.Font; BackColor = Theme.Panel; TabStop = true; AccessibleRole = AccessibleRole.List;
                SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
                scroll.Orientation = System.Windows.Forms.Orientation.Vertical; scroll.SmallChange = RowHeight; scroll.TabStop = false;
                scroll.ValueChanged += delegate { Invalidate(); };
                scroll.MouseUp += delegate { if (owner.DroppedDown && CanFocus) Focus(); };
                scroll.PreviewKeyDown += delegate(object sender, PreviewKeyDownEventArgs e) { if (e.KeyCode == Keys.Tab) e.IsInputKey = true; };
                scroll.KeyDown += delegate(object sender, KeyEventArgs e)
                {
                    if (owner.ForwardPopupCommand(e)) return;
                    if (e.KeyCode == Keys.Tab) { owner.PopupTab(e.Shift); e.Handled = true; e.SuppressKeyPress = true; }
                    else if (e.KeyCode == Keys.Enter || e.KeyCode == Keys.Escape || e.KeyCode == Keys.F4 || e.Alt) owner.HandleKey(e);
                };
                Controls.Add(scroll);
            }
            public void RefreshRange()
            {
                int view = Math.Max(1, Height - 2); long total = (long)owner.Items.Count * RowHeight;
                int maximum = (int)Math.Min(Int32.MaxValue, Math.Max(0L, total - view));
                scroll.Bounds = new Rectangle(Math.Max(1, Width - owner.ScalePixels(18) - 1), 1, owner.ScalePixels(18), view);
                scroll.SmallChange = RowHeight; scroll.SetRange(maximum, view); scroll.Visible = maximum > 0;
            }
            public void EnsureVisible(int index)
            {
                if (index < 0) return;
                int top = index * RowHeight, bottom = top + RowHeight;
                if (top < scroll.Value) scroll.Value = Math.Max(scroll.Minimum, top);
                else if (bottom > scroll.Value + Height - 2) scroll.Value = Math.Min(scroll.Maximum, Math.Max(0, bottom - (Height - 2)));
            }
            public void ScrollWheel(int delta)
            {
                int steps = delta / 120; if (steps == 0) steps = Math.Sign(delta); scroll.ScrollBy(-steps * RowHeight * 3);
            }
            protected override void OnResize(EventArgs e) { base.OnResize(e); if (scroll != null) RefreshRange(); }
            protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); if (scroll != null && owner != null) RefreshRange(); }
            protected override void OnMouseWheel(MouseEventArgs e) { base.OnMouseWheel(e); ScrollWheel(e.Delta); }
            private int IndexAt(Point point)
            {
                if (point.X < 1 || point.Y < 1 || point.X >= Width - (scroll.Visible ? scroll.Width + 1 : 1) || point.Y >= Height - 1) return -1;
                int index = (point.Y - 1 + scroll.Value) / RowHeight; return index >= 0 && index < owner.Items.Count ? index : -1;
            }
            protected override void OnMouseMove(MouseEventArgs e) { base.OnMouseMove(e); int index = IndexAt(e.Location); if (index >= 0 && owner.pendingIndex != index) { owner.pendingIndex = index; Invalidate(); } }
            protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); if (e.Button == MouseButtons.Left) { int index = IndexAt(e.Location); if (index >= 0) owner.Commit(index); } }
            protected override bool IsInputKey(Keys keyData) { return (keyData & Keys.KeyCode) != Keys.Tab || base.IsInputKey(keyData); }
            protected override void OnKeyDown(KeyEventArgs e) { base.OnKeyDown(e); if (!owner.ForwardPopupCommand(e)) owner.HandleKey(e); }
            protected override void OnKeyPress(KeyPressEventArgs e) { base.OnKeyPress(e); if (!Char.IsControl(e.KeyChar)) { owner.TypeAhead(e.KeyChar); e.Handled = true; } }
            protected override bool ProcessDialogKey(Keys keyData)
            {
                if ((keyData & Keys.KeyCode) == Keys.Tab) { owner.PopupTab((keyData & Keys.Shift) != 0); return true; }
                return base.ProcessDialogKey(keyData);
            }
            protected override void OnPaint(PaintEventArgs e)
            {
                e.Graphics.Clear(Theme.Panel); int width = Width - (scroll.Visible ? scroll.Width + 1 : 1);
                int first = scroll.Value / RowHeight, y = 1 - scroll.Value % RowHeight;
                for (int index = first; index < owner.Items.Count && y < Height - 1; index++, y += RowHeight)
                {
                    Rectangle row = new Rectangle(1, y, Math.Max(0, width - 1), RowHeight);
                    bool selected = index == owner.pendingIndex;
                    if (selected) { using (Brush brush = new SolidBrush(Theme.Raised)) e.Graphics.FillRectangle(brush, row); using (Brush brush = new SolidBrush(Theme.Amber)) e.Graphics.FillRectangle(brush, 1, y, owner.ScalePixels(3), RowHeight); }
                    Rectangle text = new Rectangle(owner.ScalePixels(11), y, Math.Max(0, width - owner.ScalePixels(21)), RowHeight);
                    TextRenderer.DrawText(e.Graphics, owner.ItemText(index), Font, text, selected ? Theme.Amber : Theme.Text, TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
                }
                using (Pen pen = new Pen(Theme.Line)) e.Graphics.DrawRectangle(pen, 0, 0, Math.Max(0, Width - 1), Math.Max(0, Height - 1));
            }
            internal Rectangle ItemBounds(int index)
            {
                Rectangle row = new Rectangle(1, 1 + index * RowHeight - scroll.Value, Width - 2 - (scroll.Visible ? scroll.Width : 0), RowHeight);
                row.Intersect(ClientRectangle); return row.Height > 0 ? RectangleToScreen(row) : Rectangle.Empty;
            }
            protected override AccessibleObject CreateAccessibilityInstance() { return new PopupAccessibleObject(this, owner); }
        }
        private sealed class DropDownAccessibleObject : ControlAccessibleObject
        {
            private readonly ThemedDropDown owner;
            public DropDownAccessibleObject(ThemedDropDown owner) : base(owner) { this.owner = owner; }
            public override AccessibleRole Role { get { return AccessibleRole.ComboBox; } }
            public override string Value
            {
                get { return owner.ItemText(owner.SelectedIndex); }
                set { for (int index = 0; index < owner.Items.Count; index++) if (String.Equals(owner.ItemText(index), value, StringComparison.CurrentCultureIgnoreCase)) { owner.SelectedIndex = index; return; } }
            }
            public override string DefaultAction { get { return owner.DroppedDown ? "Close" : "Open"; } }
            public override void DoDefaultAction() { owner.DroppedDown = !owner.DroppedDown; }
            public override AccessibleStates State { get { return base.State | AccessibleStates.Focusable | (owner.DroppedDown ? AccessibleStates.Expanded : AccessibleStates.Collapsed); } }
            public override int GetChildCount() { return owner.DroppedDown ? owner.Items.Count : 0; }
            public override AccessibleObject GetChild(int index) { return index >= 0 && index < GetChildCount() ? new ItemAccessibleObject(owner, index, this) : null; }
        }
        private sealed class PopupAccessibleObject : ControlAccessibleObject
        {
            private readonly ThemedDropDown owner;
            public PopupAccessibleObject(PopupViewport viewport, ThemedDropDown owner) : base(viewport) { this.owner = owner; }
            public override AccessibleRole Role { get { return AccessibleRole.List; } }
            public override int GetChildCount() { return owner.Items.Count; }
            public override AccessibleObject GetChild(int index) { return index >= 0 && index < owner.Items.Count ? new ItemAccessibleObject(owner, index, this) : null; }
        }
        private sealed class ItemAccessibleObject : AccessibleObject
        {
            private readonly ThemedDropDown owner;
            private readonly int index;
            private readonly AccessibleObject parent;
            public ItemAccessibleObject(ThemedDropDown owner, int index, AccessibleObject parent) { this.owner = owner; this.index = index; this.parent = parent; }
            public override string Name { get { return owner.ItemText(index); } set { } }
            public override AccessibleRole Role { get { return AccessibleRole.ListItem; } }
            public override AccessibleObject Parent { get { return parent; } }
            public override string DefaultAction { get { return "Choose"; } }
            public override void DoDefaultAction() { owner.Commit(index); }
            public override AccessibleStates State { get { return AccessibleStates.Selectable | (owner.pendingIndex == index ? AccessibleStates.Focused | AccessibleStates.Selected : AccessibleStates.None) | (Bounds.IsEmpty ? AccessibleStates.Offscreen : AccessibleStates.None); } }
            public override Rectangle Bounds { get { return owner.DroppedDown && owner.viewport != null ? owner.viewport.ItemBounds(index) : Rectangle.Empty; } }
            public override void Select(AccessibleSelection flags) { if ((flags & (AccessibleSelection.TakeSelection | AccessibleSelection.TakeFocus)) != 0) owner.SetPending(index); }
        }
    }

    public sealed class ThemedNumberBox : UserControl
    {
        private readonly TextBox editor = new TextBox();
        private readonly SpinGlyph decrease;
        private readonly SpinGlyph increase;
        private decimal minimum;
        private decimal maximum = 100;
        private decimal increment = 1;
        private decimal value;
        private int decimalPlaces;
        private bool updating;
        public event EventHandler ValueChanged;

        public ThemedNumberBox()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Panel; ForeColor = Theme.Text; Font = Theme.Body; Size = new Size(180, 34); MinimumSize = new Size(90, 28); TabStop = false; AccessibleRole = AccessibleRole.SpinButton;
            editor.BorderStyle = BorderStyle.None; editor.BackColor = Theme.Panel; editor.ForeColor = Theme.Text; editor.Font = Font; editor.TextAlign = HorizontalAlignment.Right;
            editor.AccessibleName = "Value"; editor.AccessibleRole = AccessibleRole.Text; editor.TabStop = true;
            decrease = new SpinGlyph(this, false); increase = new SpinGlyph(this, true);
            Controls.Add(editor); Controls.Add(decrease); Controls.Add(increase);
            editor.LostFocus += delegate { CommitEditor(); Invalidate(); }; editor.GotFocus += delegate { Invalidate(); };
            editor.KeyDown += delegate(object sender, KeyEventArgs e)
            {
                if (e.KeyCode == Keys.Enter) { CommitEditor(); editor.SelectAll(); e.Handled = true; e.SuppressKeyPress = true; }
                else if (e.KeyCode == Keys.Up || e.KeyCode == Keys.Down) { Step(e.KeyCode == Keys.Up ? 1 : -1); e.Handled = true; e.SuppressKeyPress = true; }
            };
            RefreshEditor(); LayoutEditor();
        }
        public decimal Minimum
        {
            get { return minimum; }
            set { minimum = value; if (maximum < minimum) maximum = minimum; SetValue(this.value); }
        }
        public decimal Maximum
        {
            get { return maximum; }
            set { maximum = value; if (minimum > maximum) minimum = maximum; SetValue(this.value); }
        }
        public decimal Increment
        {
            get { return increment; }
            set { if (value < 0) throw new ArgumentOutOfRangeException("value"); increment = value; }
        }
        public decimal Value { get { return value; } set { SetValue(value); } }
        public int DecimalPlaces
        {
            get { return decimalPlaces; }
            set { if (value < 0 || value > 28) throw new ArgumentOutOfRangeException("value"); decimalPlaces = value; RefreshEditor(); }
        }
        private void SetValue(decimal candidate)
        {
            decimal next = Math.Max(minimum, Math.Min(maximum, candidate)); bool changed = next != value; value = next; RefreshEditor();
            if (changed)
            {
                AccessibilityNotifyClients(AccessibleEvents.ValueChange, -1);
                EventHandler handler = ValueChanged; if (handler != null) handler(this, EventArgs.Empty);
            }
        }
        private void RefreshEditor()
        {
            if (editor == null) return; updating = true;
            try { editor.Text = value.ToString("F" + decimalPlaces.ToString(CultureInfo.InvariantCulture), CultureInfo.CurrentCulture); }
            finally { updating = false; }
            Invalidate();
        }
        private void CommitEditor()
        {
            if (updating) return;
            decimal parsed; if (Decimal.TryParse(editor.Text, NumberStyles.Number, CultureInfo.CurrentCulture, out parsed)) SetValue(parsed); else RefreshEditor();
        }
        private void Step(int direction)
        {
            if (!Enabled) return; CommitEditor(); decimal next;
            try { next = value + increment * direction; } catch (OverflowException) { next = direction > 0 ? maximum : minimum; }
            SetValue(next); editor.Focus(); editor.SelectAll();
        }
        private int ScalePixels(int size) { return Math.Max(1, (int)Math.Round(size * DeviceDpi / 96.0)); }
        private void LayoutEditor()
        {
            if (editor == null || decrease == null || increase == null) return;
            int button = ScalePixels(28), inset = ScalePixels(9), edge = 1;
            increase.Bounds = new Rectangle(Math.Max(edge, ClientSize.Width - button - edge), edge, button, Math.Max(1, ClientSize.Height - 2));
            decrease.Bounds = new Rectangle(Math.Max(edge, ClientSize.Width - button * 2 - edge), edge, button, Math.Max(1, ClientSize.Height - 2));
            int height = editor.PreferredHeight; editor.Bounds = new Rectangle(inset, Math.Max(edge, (ClientSize.Height - height) / 2), Math.Max(5, ClientSize.Width - button * 2 - inset - ScalePixels(6)), height);
        }
        protected override void OnResize(EventArgs e) { base.OnResize(e); LayoutEditor(); }
        protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); if (editor != null) editor.Font = Font; LayoutEditor(); }
        protected override void OnEnabledChanged(EventArgs e)
        {
            base.OnEnabledChanged(e); if (editor != null) { editor.BackColor = Enabled ? Theme.Panel : Theme.Background; editor.ForeColor = Enabled ? ForeColor : Theme.Muted; } Invalidate();
        }
        protected override void OnEnter(EventArgs e) { base.OnEnter(e); editor.Focus(); editor.SelectAll(); Invalidate(); }
        protected override void OnLeave(EventArgs e) { CommitEditor(); base.OnLeave(e); Invalidate(); }
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e); e.Graphics.Clear(Enabled ? Theme.Panel : Theme.Background);
            using (Pen pen = new Pen(Enabled && ContainsFocus ? Theme.Amber : Theme.Line)) e.Graphics.DrawRectangle(pen, 0, 0, Math.Max(0, ClientSize.Width - 1), Math.Max(0, ClientSize.Height - 1));
        }
        protected override AccessibleObject CreateAccessibilityInstance() { return new NumberAccessibleObject(this); }
        private sealed class NumberAccessibleObject : ControlAccessibleObject
        {
            private readonly ThemedNumberBox owner;
            public NumberAccessibleObject(ThemedNumberBox owner) : base(owner) { this.owner = owner; }
            public override AccessibleRole Role { get { return AccessibleRole.SpinButton; } }
            public override string Value
            {
                get { return owner.Value.ToString("F" + owner.DecimalPlaces.ToString(CultureInfo.InvariantCulture), CultureInfo.CurrentCulture); }
                set { decimal parsed; if (Decimal.TryParse(value, NumberStyles.Number, CultureInfo.CurrentCulture, out parsed)) owner.Value = parsed; }
            }
            public override string DefaultAction { get { return "Edit value"; } }
            public override void DoDefaultAction() { if (owner.Enabled) { owner.editor.Focus(); owner.editor.SelectAll(); } }
        }
        private sealed class SpinGlyph : Control
        {
            private readonly ThemedNumberBox owner;
            private readonly bool up;
            private readonly Timer repeat = new Timer();
            private bool hovered, pressed;
            public SpinGlyph(ThemedNumberBox owner, bool up)
            {
                this.owner = owner; this.up = up; TabStop = false; AccessibleName = up ? "Increase value" : "Decrease value"; AccessibleRole = AccessibleRole.SpinButton; Cursor = Cursors.Hand;
                SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
                repeat.Interval = 400; repeat.Tick += delegate { repeat.Interval = 70; owner.Step(up ? 1 : -1); };
            }
            protected override void OnMouseEnter(EventArgs e) { base.OnMouseEnter(e); hovered = true; Invalidate(); }
            protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hovered = false; Invalidate(); }
            protected override void OnMouseDown(MouseEventArgs e)
            {
                base.OnMouseDown(e); if (!Enabled || e.Button != MouseButtons.Left) return;
                pressed = true; Capture = true; owner.Step(up ? 1 : -1); repeat.Interval = 400; repeat.Start(); Invalidate();
            }
            protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); Stop(); }
            protected override void OnMouseCaptureChanged(EventArgs e) { base.OnMouseCaptureChanged(e); if (!Capture) Stop(); }
            protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); if (!Enabled) Stop(); Invalidate(); }
            private void Stop() { repeat.Stop(); pressed = false; if (Capture) Capture = false; Invalidate(); }
            protected override void OnPaint(PaintEventArgs e)
            {
                e.Graphics.Clear(!Enabled ? Theme.Background : hovered || pressed ? Theme.Raised : Theme.Panel);
                using (Pen line = new Pen(Theme.Line)) e.Graphics.DrawLine(line, 0, 0, 0, Height);
                int half = Math.Max(3, owner.ScalePixels(4)), cx = Width / 2, cy = Height / 2;
                using (Pen pen = new Pen(Enabled ? Theme.Amber : Theme.Muted, Math.Max(1.3F, DeviceDpi / 72F)))
                { e.Graphics.DrawLine(pen, cx - half, cy, cx + half, cy); if (up) e.Graphics.DrawLine(pen, cx, cy - half, cx, cy + half); }
            }
            protected override AccessibleObject CreateAccessibilityInstance() { return new SpinAccessibleObject(this, owner, up); }
            protected override void Dispose(bool disposing) { if (disposing) repeat.Dispose(); base.Dispose(disposing); }
        }
        private sealed class SpinAccessibleObject : ControlAccessibleObject
        {
            private readonly ThemedNumberBox owner;
            private readonly bool up;
            public SpinAccessibleObject(Control control, ThemedNumberBox owner, bool up) : base(control) { this.owner = owner; this.up = up; }
            public override AccessibleRole Role { get { return AccessibleRole.SpinButton; } }
            public override string DefaultAction { get { return up ? "Increase" : "Decrease"; } }
            public override void DoDefaultAction() { owner.Step(up ? 1 : -1); }
        }
    }

    public sealed class ThemedCheckBox : CheckBox
    {
        public ThemedCheckBox()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Background; ForeColor = Theme.Text; Font = Theme.Body; FlatStyle = FlatStyle.Flat;
        }
        private int ScalePixels(int value) { return Math.Max(1, (int)Math.Round(value * DeviceDpi / 96.0)); }
        public override Size GetPreferredSize(Size proposedSize)
        {
            Size text = TextRenderer.MeasureText(Text, Font); return new Size(text.Width + ScalePixels(26) + Padding.Horizontal, Math.Max(ScalePixels(24), text.Height + ScalePixels(6)) + Padding.Vertical);
        }
        protected override void OnCheckedChanged(EventArgs e) { base.OnCheckedChanged(e); Invalidate(); }
        protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
        protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(BackColor); int side = ScalePixels(17), x = Padding.Left, y = Math.Max(Padding.Top, (Height - side) / 2);
            Rectangle box = new Rectangle(x, y, side, side);
            using (Brush fill = new SolidBrush(Checked && Enabled ? Theme.Amber : Theme.Panel)) e.Graphics.FillRectangle(fill, box);
            using (Pen border = new Pen(Enabled && (Focused || Checked) ? Theme.Amber : Theme.Line)) e.Graphics.DrawRectangle(border, box);
            if (Checked)
            {
                e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
                using (Pen pen = new Pen(Enabled ? Theme.Background : Theme.Muted, Math.Max(1.5F, DeviceDpi / 64F)))
                    e.Graphics.DrawLines(pen, new Point[] { new Point(x + side / 5, y + side / 2), new Point(x + side * 2 / 5, y + side * 3 / 4), new Point(x + side * 4 / 5, y + side / 4) });
            }
            Rectangle text = new Rectangle(x + ScalePixels(25), Padding.Top, Math.Max(0, Width - x - ScalePixels(25) - Padding.Right), Height - Padding.Vertical);
            TextRenderer.DrawText(e.Graphics, Text, Font, text, Enabled ? ForeColor : Theme.Muted, TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        }
    }
}
