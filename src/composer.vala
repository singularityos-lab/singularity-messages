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
        private ScrolledWindow tray_scroll;
        private Box tray;
        private Gee.ArrayList<File> pending = new Gee.ArrayList<File> ();
        private bool attachments = true;
        private string mode = "";
        private Message? target = null;

        public signal void send_text (string text, Message? reply_to);
        public signal void edit_text (Message message, string text);
        public signal void send_files (Gee.List<File> files, string text, Message? reply_to);
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

            tray = new Box (Orientation.HORIZONTAL, 8);
            tray.add_css_class ("messages-composer-tray");
            tray_scroll = new ScrolledWindow ();
            tray_scroll.vscrollbar_policy = PolicyType.NEVER;
            tray_scroll.propagate_natural_height = true;
            tray_scroll.child = tray;
            tray_scroll.visible = false;
            append (tray_scroll);

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
            Singularity.Text.SpellIntegration.attach (view);
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

            view.buffer.changed.connect (() => update_send ());
            view.paste_clipboard.connect (() => {
                if (attachments && paste_files (view.get_clipboard ())) Signal.stop_emission_by_name (view, "paste-clipboard");
            });
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
            attachments = (f & Features.ATTACHMENTS) != 0;
            attach_btn.visible = attachments;
            if (!attachments) clear_files ();
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

        public void add_file (File file) {
            if (!attachments) return;
            foreach (var f in pending) if (f.equal (file)) return;
            pending.add (file);
            var chip = new Overlay ();
            chip.add_css_class ("messages-composer-chip");
            chip.set_size_request (72, 72);
            chip.valign = Align.START;
            chip.overflow = Overflow.HIDDEN;
            chip.tooltip_text = file.get_basename ();
            string? type = null;
            try {
                type = file.query_info (FileAttribute.STANDARD_CONTENT_TYPE, FileQueryInfoFlags.NONE).get_content_type ();
            } catch (Error e) {
            }
            if (type != null && ContentType.is_mime_type (type, "image/*")) {
                var pic = new Picture.for_file (file);
                pic.content_fit = ContentFit.COVER;
                pic.set_size_request (72, 72);
                chip.child = pic;
            } else {
                var box = new Box (Orientation.VERTICAL, 4);
                box.set_size_request (72, 72);
                box.valign = Align.CENTER;
                var icon = new Image.from_gicon (type != null ? ContentType.get_icon (type) : new ThemedIcon ("text-x-generic"));
                icon.pixel_size = 32;
                box.append (icon);
                var name = new Label (file.get_basename ());
                name.ellipsize = Pango.EllipsizeMode.MIDDLE;
                name.max_width_chars = 8;
                name.add_css_class ("caption");
                box.append (name);
                chip.child = box;
            }
            var remove = new Button.from_icon_name ("window-close-symbolic");
            remove.add_css_class ("circular");
            remove.add_css_class ("messages-composer-remove");
            remove.halign = Align.END;
            remove.valign = Align.START;
            remove.tooltip_text = _("Remove");
            remove.clicked.connect (() => {
                pending.remove (file);
                tray.remove (chip);
                forget (file);
                update_tray ();
            });
            chip.add_overlay (remove);
            tray.append (chip);
            update_tray ();
            focus_entry ();
        }

        public bool has_files () {
            return pending.size > 0;
        }

        public void clear_files () {
            foreach (var f in pending) forget (f);
            pending.clear ();
            Widget? w;
            while ((w = tray.get_first_child ()) != null) tray.remove (w);
            update_tray ();
        }

        private void update_tray () {
            tray_scroll.visible = pending.size > 0;
            update_send ();
        }

        private void update_send () {
            send_btn.sensitive = text ().strip () != "" || (pending.size > 0 && mode != "edit");
        }

        private static string paste_dir () {
            return Path.build_filename (Environment.get_user_cache_dir (), "singularity-messages", "paste");
        }

        public static void forget (File file) {
            string? path = file.get_path ();
            if (path == null || !path.has_prefix (paste_dir () + "/")) return;
            try {
                file.delete ();
            } catch (Error e) {
            }
        }

        private bool paste_files (Gdk.Clipboard clipboard) {
            var formats = clipboard.formats;
            if (formats.contain_gtype (typeof (Gdk.FileList))) {
                clipboard.read_value_async.begin (typeof (Gdk.FileList), Priority.DEFAULT, null, (o, res) => {
                    try {
                        var list = (Gdk.FileList) clipboard.read_value_async.end (res).get_boxed ();
                        foreach (var f in list.get_files ()) add_file (f);
                    } catch (Error e) {
                    }
                });
                return true;
            }
            if (!formats.contain_gtype (typeof (Gdk.Texture))) return false;
            clipboard.read_texture_async.begin (null, (o, res) => {
                try {
                    var texture = clipboard.read_texture_async.end (res);
                    if (texture == null) return;
                    DirUtils.create_with_parents (paste_dir (), 0700);
                    var stamp = new DateTime.now_local ().format ("%Y%m%d-%H%M%S");
                    string path = Path.build_filename (paste_dir (), "%s-%s.png".printf (_("Image"), stamp));
                    for (int i = 2; FileUtils.test (path, FileTest.EXISTS); i++) {
                        path = Path.build_filename (paste_dir (), "%s-%s-%d.png".printf (_("Image"), stamp, i));
                    }
                    if (texture.save_to_png (path)) add_file (File.new_for_path (path));
                } catch (Error e) {
                }
            });
            return true;
        }

        private void submit () {
            string t = text ().strip ();
            if (mode != "edit" && pending.size > 0) {
                var files = new Gee.ArrayList<File> ();
                files.add_all (pending);
                pending.clear ();
                Widget? w;
                while ((w = tray.get_first_child ()) != null) tray.remove (w);
                update_tray ();
                send_files (files, t, mode == "reply" ? target : null);
                set_text ("");
                mode = "";
                target = null;
                context_bar.visible = false;
                return;
            }
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
