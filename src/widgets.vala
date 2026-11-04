using Gtk;
using Singularity.Messaging;

namespace Singularity.Apps.Messages {

    public string format_when (int64 stamp) {
        if (stamp <= 0) return "";
        var d = new DateTime.from_unix_local (stamp);
        var now = new DateTime.now_local ();
        if (d.get_year () == now.get_year () && d.get_day_of_year () == now.get_day_of_year ()) return d.format ("%H:%M");
        var yesterday = now.add_days (-1);
        if (d.get_year () == yesterday.get_year () && d.get_day_of_year () == yesterday.get_day_of_year ()) return _("Yesterday");
        if (now.difference (d) < 6 * TimeSpan.DAY) return d.format ("%a");
        if (d.get_year () == now.get_year ()) return d.format ("%e %b").strip ();
        return d.format ("%e %b %Y").strip ();
    }

    public string format_day (int64 stamp) {
        var d = new DateTime.from_unix_local (stamp);
        var now = new DateTime.now_local ();
        if (d.get_year () == now.get_year () && d.get_day_of_year () == now.get_day_of_year ()) return _("Today");
        var yesterday = now.add_days (-1);
        if (d.get_year () == yesterday.get_year () && d.get_day_of_year () == yesterday.get_day_of_year ()) return _("Yesterday");
        if (d.get_year () == now.get_year ()) return d.format ("%A %e %B").replace ("  ", " ");
        return d.format ("%e %B %Y").strip ();
    }

    public string initials_of (string name) {
        var sb = new StringBuilder ();
        foreach (string part in name.strip ().split (" ")) {
            if (part == "" || sb.len >= 2) continue;
            unichar c = part.get_char (0);
            if (c.isalpha ()) sb.append_unichar (c.toupper ());
        }
        return sb.str;
    }

    public class ChatAvatar : Widget {
        private const string[] COLORS = { "#3584e4", "#2190a4", "#3a944a", "#c88800", "#ed5b00", "#e62d42", "#d56199", "#9141ac", "#6f8396", "#986a44" };

        private Gdk.Texture? texture;
        private string initials = "";
        private string seed = "";
        private string group_icon = "";
        private int size;

        public ChatAvatar (int size) {
            this.size = size;
            add_css_class ("messages-avatar");
        }

        public void set_person (string name, string? image, bool group = false) {
            seed = name;
            initials = initials_of (name);
            group_icon = group ? "system-users-symbolic" : "";
            texture = null;
            if (image != null) {
                try {
                    texture = Gdk.Texture.from_filename (image);
                } catch (Error e) {
                    texture = null;
                }
            }
            queue_draw ();
        }

        public override void measure (Orientation o, int for_size, out int minimum, out int natural, out int mb, out int nb) {
            minimum = natural = size;
            mb = nb = -1;
        }

        public override void snapshot (Snapshot snap) {
            float s = (float) int.min (get_width (), get_height ());
            var rect = Graphene.Rect ().init ((get_width () - s) / 2, (get_height () - s) / 2, s, s);
            var clip = Gsk.RoundedRect ().init_from_rect (rect, s / 2);
            snap.push_rounded_clip (clip);
            if (texture != null) {
                float tw = texture.width, th = texture.height;
                float scale = float.max (s / tw, s / th);
                var tr = Graphene.Rect ().init (rect.origin.x + (s - tw * scale) / 2, rect.origin.y + (s - th * scale) / 2, tw * scale, th * scale);
                snap.append_texture (texture, tr);
            } else if (initials == "") {
                var bg = Gdk.RGBA ();
                bg.parse (COLORS[seed.hash () % COLORS.length]);
                snap.append_color (bg, rect);
                var theme = IconTheme.get_for_display (get_display ());
                int glyph = (int) (s * 0.55f);
                var icon = theme.lookup_icon (group_icon != "" ? group_icon : "avatar-default-symbolic", null, glyph, 1, TextDirection.NONE, 0);
                var white = Gdk.RGBA ();
                white.parse ("#ffffff");
                snap.save ();
                snap.translate (Graphene.Point () { x = rect.origin.x + (s - glyph) / 2, y = rect.origin.y + (s - glyph) / 2 });
                icon.snapshot_symbolic (snap, glyph, glyph, { white });
                snap.restore ();
            } else {
                var bg = Gdk.RGBA ();
                bg.parse (COLORS[seed.hash () % COLORS.length]);
                snap.append_color (bg, rect);
                var layout = create_pango_layout (initials);
                var fd = new Pango.FontDescription ();
                fd.set_weight (Pango.Weight.BOLD);
                fd.set_absolute_size (s * 0.38 * Pango.SCALE);
                layout.set_font_description (fd);
                int lw, lh;
                layout.get_pixel_size (out lw, out lh);
                snap.save ();
                snap.translate (Graphene.Point () { x = rect.origin.x + (s - lw) / 2, y = rect.origin.y + (s - lh) / 2 });
                var white = Gdk.RGBA ();
                white.parse ("#ffffff");
                snap.append_layout (layout, white);
                snap.restore ();
            }
            snap.pop ();
        }
    }

    public class ConversationRow : ListBoxRow {
        public Entry entry { get; private set; }

        private ChatAvatar avatar;
        private Image service;
        private Label title;
        private Label when;
        private Label preview;
        private Label count;
        private Image muted;
        private Image pin;

        public ConversationRow () {
            add_css_class ("messages-conversation-row");
            var box = new Box (Orientation.HORIZONTAL, 10);
            box.margin_top = 7;
            box.margin_bottom = 7;
            box.margin_start = 10;
            box.margin_end = 10;
            var overlay = new Overlay ();
            avatar = new ChatAvatar (40);
            overlay.child = avatar;
            service = new Image ();
            service.pixel_size = 12;
            service.halign = Align.END;
            service.valign = Align.END;
            service.add_css_class ("messages-service-badge");
            overlay.add_overlay (service);
            overlay.valign = Align.CENTER;
            box.append (overlay);
            var texts = new Box (Orientation.VERTICAL, 2);
            texts.hexpand = true;
            texts.valign = Align.CENTER;
            var head = new Box (Orientation.HORIZONTAL, 6);
            title = new Label ("");
            title.xalign = 0;
            title.hexpand = true;
            title.ellipsize = Pango.EllipsizeMode.END;
            title.add_css_class ("messages-row-title");
            head.append (title);
            muted = new Image.from_icon_name ("notifications-disabled-symbolic");
            muted.pixel_size = 12;
            muted.add_css_class ("dim-label");
            muted.tooltip_text = _("Muted");
            head.append (muted);
            pin = new Image.from_icon_name ("view-pin-symbolic");
            pin.pixel_size = 12;
            pin.add_css_class ("dim-label");
            pin.tooltip_text = _("Pinned");
            pin.visible = false;
            head.append (pin);
            when = new Label ("");
            when.add_css_class ("dim-label");
            when.add_css_class ("caption");
            when.add_css_class ("numeric");
            head.append (when);
            texts.append (head);
            var foot = new Box (Orientation.HORIZONTAL, 6);
            preview = new Label ("");
            preview.xalign = 0;
            preview.hexpand = true;
            preview.ellipsize = Pango.EllipsizeMode.END;
            preview.single_line_mode = true;
            preview.add_css_class ("dim-label");
            foot.append (preview);
            count = new Label ("");
            count.add_css_class ("messages-unread");
            count.valign = Align.CENTER;
            foot.append (count);
            texts.append (foot);
            box.append (texts);
            child = box;
        }

        public void set_pinned (bool pinned) {
            pin.visible = pinned;
        }

        public void bind (Entry e, string? image) {
            entry = e;
            var c = e.conversation;
            title.label = c.title != "" ? c.title : _("Conversation");
            avatar.set_person (c.title, image, c.kind != ConversationKind.DIRECT);
            service.icon_name = e.channel.icon_name;
            service.tooltip_text = e.channel.title;
            when.label = format_when (c.activity);
            string p = c.last_preview;
            if (c.last_author != "" && (c.kind != ConversationKind.DIRECT || c.last_author == _("You"))) p = "%s: %s".printf (c.last_author, p);
            preview.label = p;
            count.visible = c.unread > 0;
            if (c.counts) count.remove_css_class ("quiet");
            else count.add_css_class ("quiet");
            if (c.mentioned) count.label = "@";
            else if (c.unread > 99) count.label = "99+";
            else count.label = c.unread.to_string ();
            muted.visible = c.muted;
            if (c.unread > 0) add_css_class ("unread");
            else remove_css_class ("unread");
            string a11y = c.unread > 0 ? _("%s, %d unread, %s").printf (title.label, c.unread, p) : "%s, %s".printf (title.label, p);
            update_property (AccessibleProperty.LABEL, a11y, -1);
        }
    }

    public class DayRow : ListBoxRow {
        public DayRow (int64 stamp) {
            activatable = false;
            selectable = false;
            focusable = false;
            var l = new Label (format_day (stamp));
            l.add_css_class ("messages-day");
            l.halign = Align.CENTER;
            l.margin_top = 12;
            l.margin_bottom = 6;
            child = l;
        }
    }

    public class MessageRow : ListBoxRow {
        public Message message { get; private set; }

        public signal void react (string emoji);
        public signal void open_attachment (Attachment a);
        public signal void retry ();
        public signal void preview (Attachment a, Button target);

        private Gee.ArrayList<Attachment> preview_items = new Gee.ArrayList<Attachment> ();
        private Gee.ArrayList<Button> preview_targets = new Gee.ArrayList<Button> ();

        public MessageRow (Message m, bool show_author, bool group, string? avatar_path) {
            message = m;
            activatable = false;
            selectable = false;
            add_css_class ("messages-message-row");
            if (m.system) {
                var l = new Label (m.text);
                l.wrap = true;
                l.wrap_mode = Pango.WrapMode.WORD_CHAR;
                l.justify = Justification.CENTER;
                l.add_css_class ("messages-system");
                l.margin_top = 4;
                l.margin_bottom = 4;
                l.margin_start = 40;
                l.margin_end = 40;
                child = l;
                return;
            }
            var line = new Box (Orientation.HORIZONTAL, 8);
            line.margin_start = 14;
            line.margin_end = 14;
            line.margin_top = show_author ? 6 : 1;
            line.margin_bottom = 1;
            if (group && !m.outgoing) {
                var av = new ChatAvatar (28);
                av.valign = Align.END;
                av.set_person (m.author_name, avatar_path);
                av.opacity = show_author ? 1.0 : 0.0;
                line.append (av);
            }
            var column = new Box (Orientation.VERTICAL, 2);
            column.halign = m.outgoing ? Align.END : Align.START;
            column.hexpand = true;
            if (show_author && group && !m.outgoing && m.author_name != "") {
                var who = new Label (m.author_name);
                who.xalign = 0;
                who.add_css_class ("messages-author");
                who.margin_start = 10;
                column.append (who);
            }
            var bubble = new Box (Orientation.VERTICAL, 4);
            bubble.add_css_class ("messages-bubble");
            bubble.add_css_class (m.outgoing ? "outgoing" : "incoming");
            if (m.deleted) bubble.add_css_class ("deleted");
            if (m.reply_preview != "" && !m.deleted) {
                var quote = new Label (m.reply_preview);
                quote.xalign = 0;
                quote.ellipsize = Pango.EllipsizeMode.END;
                quote.max_width_chars = 48;
                quote.add_css_class ("messages-quote");
                bubble.append (quote);
            }
            if (!m.deleted) {
                foreach (var a in m.attachments) bubble.append (attachment_widget (a));
            }
            string body = m.deleted ? _("This message was deleted") : m.text;
            if (body != "") {
                var text = new Label (body);
                text.xalign = 0;
                text.wrap = true;
                text.wrap_mode = Pango.WrapMode.WORD_CHAR;
                text.max_width_chars = 60;
                text.selectable = true;
                text.can_focus = false;
                text.add_css_class ("messages-text");
                bubble.append (text);
            }
            var meta = new Box (Orientation.HORIZONTAL, 4);
            meta.halign = Align.END;
            if (m.edited && !m.deleted) {
                var ed = new Label (_("edited"));
                ed.add_css_class ("messages-meta");
                meta.append (ed);
            }
            var time = new Label (m.time > 0 ? new DateTime.from_unix_local (m.time).format ("%H:%M") : "");
            time.add_css_class ("messages-meta");
            time.add_css_class ("numeric");
            meta.append (time);
            if (m.outgoing && m.state != MessageState.SENT) {
                var st = new Image.from_icon_name (m.state == MessageState.PENDING ? "content-loading-symbolic" : "dialog-error-symbolic");
                st.pixel_size = 12;
                st.tooltip_text = m.state == MessageState.PENDING ? _("Sending") : _("Not sent");
                st.add_css_class ("messages-meta");
                if (m.state == MessageState.FAILED) st.add_css_class ("error");
                meta.append (st);
            }
            bubble.append (meta);
            column.append (bubble);
            if (m.state == MessageState.FAILED) {
                var again = new Button.with_label (_("Not sent. Try Again"));
                again.add_css_class ("flat");
                again.add_css_class ("messages-retry");
                again.halign = Align.END;
                again.clicked.connect (() => retry ());
                column.append (again);
            }
            if (m.reactions.size > 0) {
                var chips = new Box (Orientation.HORIZONTAL, 4);
                chips.halign = m.outgoing ? Align.END : Align.START;
                foreach (var e in m.reactions.entries) {
                    var chip = new ToggleButton.with_label ("%s %d".printf (e.key, e.value));
                    chip.active = m.own_reactions.contains (e.key);
                    chip.add_css_class ("messages-reaction");
                    string emoji = e.key;
                    chip.clicked.connect (() => react (emoji));
                    chips.append (chip);
                }
                column.append (chips);
            }
            line.append (column);
            child = line;
            string who_said = m.outgoing ? _("You") : m.author_name;
            update_property (AccessibleProperty.LABEL, "%s: %s".printf (who_said, m.deleted ? body : m.preview ()), -1);
        }

        private Widget attachment_widget (Attachment a) {
            var btn = new Button ();
            btn.add_css_class ("messages-attachment");
            var box = new Box (Orientation.HORIZONTAL, 8);
            var icon = new Image.from_gicon (ContentType.get_icon (a.mime != "" ? a.mime : "application/octet-stream"));
            icon.pixel_size = 32;
            box.append (icon);
            var texts = new Box (Orientation.VERTICAL, 0);
            var name = new Label (a.name != "" ? a.name : _("Attachment"));
            name.xalign = 0;
            name.ellipsize = Pango.EllipsizeMode.MIDDLE;
            name.max_width_chars = 32;
            texts.append (name);
            if (a.size > 0) {
                var size = new Label (format_size (a.size));
                size.xalign = 0;
                size.add_css_class ("dim-label");
                size.add_css_class ("caption");
                texts.append (size);
            }
            box.append (texts);
            btn.child = box;
            btn.tooltip_text = _("Open %s").printf (name.label);
            btn.clicked.connect (() => open_attachment (a));
            if (is_image (a)) {
                preview_items.add (a);
                preview_targets.add (btn);
            }
            return btn;
        }

        public static bool is_image (Attachment a) {
            if (a.mime.has_prefix ("image/")) return true;
            bool uncertain;
            string type = ContentType.guess (a.name, null, out uncertain);
            return !uncertain && ContentType.is_mime_type (type, "image/*");
        }

        public void request_previews () {
            for (int i = 0; i < preview_items.size; i++) preview (preview_items[i], preview_targets[i]);
        }

        public static void show_preview (Button btn, Gdk.Texture texture) {
            int w = int.min (280, texture.width);
            int h = (int) ((double) w * texture.height / int.max (1, texture.width));
            if (h > 320) {
                h = 320;
                w = int.max (48, (int) ((double) h * texture.width / int.max (1, texture.height)));
            }
            var pic = new Picture.for_paintable (texture);
            pic.content_fit = ContentFit.COVER;
            pic.can_shrink = true;
            pic.set_size_request (w, h);
            btn.remove_css_class ("messages-attachment");
            btn.add_css_class ("messages-attachment-image");
            btn.halign = Align.START;
            btn.overflow = Overflow.HIDDEN;
            btn.child = pic;
        }
    }
}
