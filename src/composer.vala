using Gtk;
using Singularity.Messaging;

namespace Singularity.Apps.Messages {

    public class Composer : Box {
        private TextView view;
        private Button send_btn;
        private Button attach_btn;
        private MenuButton emoji_btn;
        private Box context_bar;
        private Label context_label;
        private string mode = "";
        private Message? target = null;

        public signal void send_text (string text, Message? reply_to);
        public signal void edit_text (Message message, string text);
        public signal void attach ();
        public signal void edit_last ();

        public Composer () {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class ("messages-composer");

            context_bar = new Box (Orientation.HORIZONTAL, 8);
            context_bar.add_css_class ("messages-composer-context");
            context_bar.visible = false;
            var ctx_icon = new Image.from_icon_name ("mail-reply-sender-symbolic");
            ctx_icon.pixel_size = 16;
            context_bar.append (ctx_icon);
            context_label = new Label ("");
            context_label.xalign = 0;
            context_label.hexpand = true;
            context_label.ellipsize = Pango.EllipsizeMode.END;
            context_bar.append (context_label);
            var cancel = new Button.from_icon_name ("window-close-symbolic");
            cancel.add_css_class ("flat");
            cancel.tooltip_text = _("Cancel");
            cancel.clicked.connect (() => clear_context ());
            context_bar.append (cancel);
            append (context_bar);

            var row = new Box (Orientation.HORIZONTAL, 6);
            row.add_css_class ("messages-composer-row");
            attach_btn = new Button.from_icon_name ("mail-attachment-symbolic");
            attach_btn.add_css_class ("flat");
            attach_btn.valign = Align.END;
            attach_btn.tooltip_text = _("Send a File");
            attach_btn.clicked.connect (() => attach ());
            row.append (attach_btn);

            var frame = new Box (Orientation.HORIZONTAL, 0);
            frame.add_css_class ("messages-entry");
            frame.hexpand = true;
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.propagate_natural_height = true;
            scroll.max_content_height = 160;
            scroll.hexpand = true;
            view = new TextView ();
            view.wrap_mode = WrapMode.WORD_CHAR;
            view.accepts_tab = false;
            view.top_margin = 8;
            view.bottom_margin = 8;
            view.left_margin = 10;
            view.right_margin = 10;
            view.add_css_class ("messages-entry-view");
            view.update_property (AccessibleProperty.LABEL, _("Message"), -1);
            scroll.child = view;
            frame.append (scroll);

            var chooser = new EmojiChooser ();
            chooser.emoji_picked.connect ((e) => {
                view.buffer.insert_at_cursor (e, -1);
                view.grab_focus ();
            });
            emoji_btn = new MenuButton ();
            emoji_btn.icon_name = "face-smile-symbolic";
            emoji_btn.add_css_class ("flat");
            emoji_btn.valign = Align.END;
            emoji_btn.tooltip_text = _("Insert Emoji");
            emoji_btn.popover = chooser;
            frame.append (emoji_btn);
            row.append (frame);

            send_btn = new Button.from_icon_name ("mail-send-symbolic");
            send_btn.add_css_class ("suggested-action");
            send_btn.add_css_class ("circular");
            send_btn.valign = Align.END;
            send_btn.tooltip_text = _("Send (Enter)");
            send_btn.sensitive = false;
            send_btn.clicked.connect (() => submit ());
            row.append (send_btn);
            append (row);

            view.buffer.changed.connect (() => send_btn.sensitive = text ().strip () != "");
            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((val, code, state) => {
                bool shift = (state & Gdk.ModifierType.SHIFT_MASK) != 0;
                if ((val == Gdk.Key.Return || val == Gdk.Key.KP_Enter) && !shift) {
                    submit ();
                    return true;
                }
                if (val == Gdk.Key.Escape && mode != "") {
                    clear_context ();
                    return true;
                }
                if (val == Gdk.Key.Up && text () == "" && mode == "") {
                    edit_last ();
                    return true;
                }
                return false;
            });
            view.add_controller (keys);
        }

        public void set_features (Features f, bool read_only) {
            attach_btn.visible = (f & Features.ATTACHMENTS) != 0;
            sensitive = !read_only;
            view.update_property (AccessibleProperty.PLACEHOLDER, read_only ? _("Only some people can write here") : _("Message"), -1);
        }

        public string text () {
            TextIter a, b;
            view.buffer.get_bounds (out a, out b);
            return view.buffer.get_text (a, b, false);
        }

        public void set_text (string t) {
            view.buffer.text = t;
        }

        public void focus_entry () {
            view.grab_focus ();
        }

        public void reply_to (Message m) {
            mode = "reply";
            target = m;
            context_label.label = _("Replying to %s: %s").printf (m.outgoing ? _("yourself") : m.author_name, m.preview ());
            context_bar.visible = true;
            focus_entry ();
        }

        public void edit (Message m) {
            mode = "edit";
            target = m;
            context_label.label = _("Editing your message");
            context_bar.visible = true;
            set_text (m.text);
            focus_entry ();
        }

        public void clear_context () {
            if (mode == "edit") set_text ("");
            mode = "";
            target = null;
            context_bar.visible = false;
        }

        private void submit () {
            string t = text ().strip ();
            if (t == "") return;
            if (mode == "edit" && target != null) edit_text (target, t);
            else send_text (t, mode == "reply" ? target : null);
            set_text ("");
            mode = "";
            target = null;
            context_bar.visible = false;
        }
    }
}
