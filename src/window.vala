using Gtk;
using Singularity.Messaging;
using Singularity.Widgets;

namespace Singularity.Apps.Messages {

    public class MessagesWindow : Singularity.Widgets.Window {
        private MessagesApp app;
        private Engine engine;
        private AppSidebar sidebar;
        private Box sidebar_box;
        private Gee.HashMap<string, SidebarRow> nav_rows = new Gee.HashMap<string, SidebarRow> ();
        private Gee.HashMap<string, Label> nav_counts = new Gee.HashMap<string, Label> ();
        private Stack main_stack;
        private ListBox list;
        private Stack list_stack;
        private StatusPage list_empty;
        private Stack chat_stack;
        private ListBox thread;
        private ScrolledWindow thread_scroll;
        private ChatAvatar head_avatar;
        private Label head_title;
        private Label head_subtitle;
        private Composer composer;
        private Banner banner;
        private SearchBubble search;
        private Overlay overlay;
        private Singularity.Widgets.Toast? last_toast = null;
        private Gee.HashMap<string, ConversationRow> rows = new Gee.HashMap<string, ConversationRow> ();
        private string filter = "all";
        private string query = "";
        private Channel? open_channel = null;
        private string open_conversation = "";
        private bool stick_bottom = true;
        private uint rebuild_id = 0;
        private bool updating_selection = false;

        public MessagesWindow (MessagesApp app) {
            Object (application: app);
            this.app = app;
            engine = app.engine;
            set_title (_("Messages"));
            set_default_size (1180, 780);
            set_size_request (420, 480);

            sidebar = new AppSidebar (220);
            sidebar_box = new Box (Orientation.VERTICAL, 2);
            sidebar_box.valign = Align.START;
            sidebar.box.append (sidebar_box);
            set_sidebar (sidebar);
            sidebar.add_bubble_icon ("chat-message-new-symbolic", _("New Conversation (Ctrl+N)"), () => new_conversation ());

            search = add_bubble_search (_("Search Conversations"), (t) => {
                query = t.strip ();
                queue_rebuild ();
            });
            add_bubble_icon ("view-refresh-symbolic", _("Refresh (Ctrl+R)"), () => engine.refresh_all ());

            main_stack = new Stack ();
            main_stack.transition_type = StackTransitionType.CROSSFADE;
            main_stack.add_named (build_welcome (), "welcome");
            main_stack.add_named (build_main (), "main");
            overlay = new Overlay ();
            overlay.child = main_stack;
            set_content (overlay);

            install_actions ();
            engine.channels_changed.connect (() => {
                rebuild_sidebar ();
                queue_rebuild ();
                update_start ();
            });
            engine.conversations_changed.connect (() => {
                queue_rebuild ();
                update_counts ();
            });
            engine.messages_changed.connect ((ch, conv) => {
                if (open_channel == null || open_channel.id != ch || open_conversation != conv) return;
                bool follow = stick_bottom;
                rebuild_thread ();
                if (follow) scroll_to_end ();
            });
            engine.problem.connect ((ch, msg) => {
                if (open_channel != null && open_channel.id == ch) show_toast (msg);
            });
            app.avatars.ready.connect ((key) => {
                var row = rows[key];
                if (row != null) row.bind (row.entry, app.avatars.lookup (row.entry.channel, row.entry.conversation));
                if (open_channel != null && Engine.key_of (open_channel.id, open_conversation) == key) update_head ();
            });
            notify["is-active"].connect (() => sync_focus ());
            rebuild_sidebar ();
            update_start ();
            queue_rebuild ();
        }

        private Widget build_welcome () {
            var welcome = new WelcomePage ();
            welcome.app_icon_name = "dev.sinty.messages";
            welcome.title = _("Messages");
            welcome.subtitle = _("Your chats from Nextcloud Talk, Google Chat, Microsoft Teams, your phone and nearby computers, all in one place.");
            welcome.add_action ("folder-remote", _("Connect an Online Account"), _("Accounts added in Settings bring their chats here by themselves"), () => app.open_accounts ());
            welcome.add_action ("phone", _("Pair a Phone"), _("Read and send text messages from your phone with Nearby"), () => NearbyClient.open_app ());
            return welcome;
        }

        private Widget build_main () {
            list = new ListBox ();
            list.add_css_class ("messages-list");
            list.selection_mode = SelectionMode.SINGLE;
            list.update_property (AccessibleProperty.LABEL, _("Conversations"), -1);
            list.row_selected.connect ((row) => {
                if (updating_selection) return;
                var r = row as ConversationRow;
                if (r != null) open_entry (r.entry.channel, r.entry.conversation.id);
            });
            var click = new GestureClick ();
            click.button = Gdk.BUTTON_SECONDARY;
            click.pressed.connect ((n, x, y) => {
                var r = list.get_row_at_y ((int) y) as ConversationRow;
                if (r != null) conversation_menu (r);
            });
            list.add_controller (click);
            var list_scroll = new ScrolledWindow ();
            list_scroll.hscrollbar_policy = PolicyType.NEVER;
            list_scroll.vexpand = true;
            list_scroll.child = list;

            list_empty = new StatusPage ();
            list_empty.icon_name = "dev.sinty.messages";
            list_empty.compact = true;
            list_stack = new Stack ();
            list_stack.add_named (list_scroll, "list");
            list_stack.add_named (list_empty, "empty");
            list_stack.vexpand = true;

            banner = new Banner ();
            banner.visible = false;
            banner.button_clicked.connect (() => app.open_accounts ());

            var list_pane = new Box (Orientation.VERTICAL, 0);
            list_pane.add_css_class ("messages-list-pane");
            list_pane.append (banner);
            list_pane.append (list_stack);
            list_pane.set_size_request (300, -1);

            chat_stack = new Stack ();
            chat_stack.transition_type = StackTransitionType.CROSSFADE;
            var none = new StatusPage ();
            none.icon_name = "dev.sinty.messages";
            none.title = _("No Conversation Selected");
            none.description = _("Pick a conversation on the left, or start a new one.");
            var start_btn = new Button.with_label (_("New Conversation"));
            start_btn.add_css_class ("pill");
            start_btn.add_css_class ("suggested-action");
            start_btn.halign = Align.CENTER;
            start_btn.clicked.connect (() => new_conversation ());
            none.child = start_btn;
            chat_stack.add_named (none, "none");
            chat_stack.add_named (build_chat (), "chat");
            chat_stack.hexpand = true;
            chat_stack.set_size_request (380, -1);

            var paned = new Paned (Orientation.HORIZONTAL);
            paned.start_child = list_pane;
            paned.end_child = chat_stack;
            paned.resize_start_child = false;
            paned.shrink_start_child = false;
            paned.shrink_end_child = false;
            paned.position = 340;
            paned.wide_handle = false;
            paned.vexpand = true;

            var page = new Box (Orientation.VERTICAL, 0);
            page.append (paned);
            Singularity.Widgets.apply_view_edge (page);
            return page;
        }

        private Widget build_chat () {
            var head = new Box (Orientation.HORIZONTAL, 10);
            head.add_css_class ("messages-chat-head");
            head_avatar = new ChatAvatar (32);
            head.append (head_avatar);
            var texts = new Box (Orientation.VERTICAL, 0);
            texts.valign = Align.CENTER;
            texts.hexpand = true;
            head_title = new Label ("");
            head_title.xalign = 0;
            head_title.ellipsize = Pango.EllipsizeMode.END;
            head_title.add_css_class ("heading");
            texts.append (head_title);
            head_subtitle = new Label ("");
            head_subtitle.xalign = 0;
            head_subtitle.ellipsize = Pango.EllipsizeMode.END;
            head_subtitle.add_css_class ("dim-label");
            head_subtitle.add_css_class ("caption");
            texts.append (head_subtitle);
            head.append (texts);

            thread = new ListBox ();
            thread.add_css_class ("messages-thread");
            thread.selection_mode = SelectionMode.NONE;
            thread.update_property (AccessibleProperty.LABEL, _("Messages"), -1);
            var press = new GestureClick ();
            press.button = Gdk.BUTTON_SECONDARY;
            press.pressed.connect ((n, x, y) => {
                var r = thread.get_row_at_y ((int) y) as MessageRow;
                if (r != null) message_menu (r, x, y);
            });
            thread.add_controller (press);
            thread_scroll = new ScrolledWindow ();
            thread_scroll.hscrollbar_policy = PolicyType.NEVER;
            thread_scroll.vexpand = true;
            thread_scroll.child = thread;
            var adj = thread_scroll.vadjustment;
            adj.value_changed.connect (() => {
                stick_bottom = adj.value >= adj.upper - adj.page_size - 24;
            });
            adj.notify["upper"].connect (() => {
                if (stick_bottom) adj.value = adj.upper - adj.page_size;
            });

            composer = new Composer ();
            composer.send_text.connect ((text, reply) => {
                if (open_channel == null) return;
                scroll_to_end ();
                engine.send.begin (open_channel, open_conversation, text, reply != null ? reply.id : null);
            });
            composer.edit_text.connect ((m, text) => {
                if (open_channel != null) engine.edit.begin (open_channel, open_conversation, m, text);
            });
            composer.attach.connect (() => pick_files ());
            composer.edit_last.connect (() => {
                if (open_channel == null || !open_channel.supports (Features.EDIT)) return;
                var msgs = engine.messages (open_channel.id, open_conversation);
                for (int i = msgs.size - 1; i >= 0; i--) {
                    var m = msgs[i];
                    if (m.outgoing && !m.deleted && m.state == MessageState.SENT && m.attachments.size == 0) {
                        composer.edit (m);
                        return;
                    }
                }
            });

            var drop = new DropTarget (typeof (Gdk.FileList), Gdk.DragAction.COPY);
            drop.drop.connect ((val, x, y) => {
                var files = (Gdk.FileList) val.get_boxed ();
                if (open_channel == null || !open_channel.supports (Features.ATTACHMENTS)) return false;
                foreach (var f in files.get_files ()) engine.upload.begin (open_channel, open_conversation, f, "");
                return true;
            });

            var chat = new Box (Orientation.VERTICAL, 0);
            chat.add_css_class ("messages-chat");
            chat.append (head);
            chat.append (thread_scroll);
            chat.append (composer);
            chat.add_controller (drop);
            return chat;
        }

        private void install_actions () {
            var new_conv = new SimpleAction ("new-conversation", null);
            new_conv.activate.connect (() => new_conversation ());
            add_action (new_conv);
            var new_group = new SimpleAction ("new-group", null);
            new_group.activate.connect (() => {
                var d = new NewGroupDialog (app, this, engine);
                d.started.connect ((ch, id) => open_by_id (ch.id, id));
                d.open_dialog ();
            });
            add_action (new_group);
            var refresh = new SimpleAction ("refresh", null);
            refresh.activate.connect (() => engine.refresh_all ());
            add_action (refresh);
            var find = new SimpleAction ("find", null);
            find.activate.connect (() => search.grab_focus_entry ());
            add_action (find);
            var all_read = new SimpleAction ("mark-all-read", null);
            all_read.activate.connect (() => engine.mark_all_read ());
            add_action (all_read);
            var attach = new SimpleAction ("attach", null);
            attach.activate.connect (() => pick_files ());
            add_action (attach);
            var next = new SimpleAction ("next-conversation", null);
            next.activate.connect (() => step (1));
            add_action (next);
            var prev = new SimpleAction ("previous-conversation", null);
            prev.activate.connect (() => step (-1));
            add_action (prev);
            var close = new SimpleAction ("close", null);
            close.activate.connect (() => this.close ());
            add_action (close);
        }

        private void step (int delta) {
            var current = list.get_selected_row ();
            int index = current != null ? current.get_index () + delta : 0;
            var row = list.get_row_at_index (index);
            if (row != null) list.select_row (row);
        }

        private void update_start () {
            bool any = engine.get_channels ().size > 0;
            main_stack.visible_child_name = any ? "main" : "welcome";
            set_sidebar_visible (any);
        }

        private SidebarRow nav_row (string id, string icon, string label) {
            var row = new SidebarRow (icon, label);
            var count = new Label ("");
            count.add_css_class ("messages-nav-count");
            count.visible = false;
            var inner = row.get_child () as Box;
            if (inner != null) inner.append (count);
            nav_counts[id] = count;
            row.clicked.connect (() => {
                filter = id;
                foreach (var e in nav_rows.entries) e.value.set_active (e.key == filter);
                queue_rebuild ();
            });
            nav_rows[id] = row;
            row.set_active (id == filter);
            return row;
        }

        private void rebuild_sidebar () {
            Widget? child;
            while ((child = sidebar_box.get_first_child ()) != null) sidebar_box.remove (child);
            nav_rows.clear ();
            nav_counts.clear ();
            sidebar_box.append (nav_row ("all", "mail-inbox-symbolic", _("All Conversations")));
            sidebar_box.append (nav_row ("unread", "mail-unread-symbolic", _("Unread")));
            sidebar_box.append (nav_row ("direct", "avatar-default-symbolic", _("People")));
            sidebar_box.append (nav_row ("group", "system-users-symbolic", _("Groups")));
            if (engine.get_channels ().size > 0) {
                var label = new SidebarSectionLabel (_("Accounts"));
                sidebar_box.append (label);
                foreach (var ch in engine.get_channels ()) {
                    var row = nav_row (ch.id, ch.icon_name, ch.title);
                    if (ch.attention != "") row.tooltip_text = ch.attention.has_prefix ("!") ? ch.attention.substring (1) : ch.attention;
                    sidebar_box.append (row);
                }
            }
            if (!nav_rows.has_key (filter)) {
                filter = "all";
                nav_rows["all"].set_active (true);
            }
            update_counts ();
        }

        private void update_counts () {
            int total = 0;
            var per = new Gee.HashMap<string, int> ();
            foreach (var e in engine.entries ()) {
                if (!e.conversation.counts) continue;
                total += e.conversation.unread;
                per[e.channel.id] = (per.has_key (e.channel.id) ? per[e.channel.id] : 0) + e.conversation.unread;
            }
            foreach (var e in nav_counts.entries) {
                int n = e.key == "all" || e.key == "unread" ? total : (per.has_key (e.key) ? per[e.key] : 0);
                if (e.key == "direct" || e.key == "group") n = 0;
                e.value.label = n.to_string ();
                e.value.visible = n > 0;
            }
            app.notifier.badge (total);
            string? problem = null;
            foreach (var ch in engine.get_channels ()) {
                if (ch.attention != "") {
                    problem = "%s: %s".printf (ch.title, ch.attention.has_prefix ("!") ? ch.attention.substring (1) : ch.attention);
                    break;
                }
            }
            banner.visible = problem != null;
            if (problem != null) {
                banner.title = problem;
                banner.button_label = _("Settings");
            }
        }

        private void queue_rebuild () {
            if (rebuild_id != 0) return;
            rebuild_id = Idle.add (() => {
                rebuild_id = 0;
                rebuild_list ();
                return Source.REMOVE;
            });
        }

        private bool accepts (Entry e) {
            switch (filter) {
                case "all": return true;
                case "unread": return e.conversation.unread > 0 || (open_channel == e.channel && open_conversation == e.conversation.id);
                case "direct": return e.conversation.kind == ConversationKind.DIRECT;
                case "group": return e.conversation.kind != ConversationKind.DIRECT;
                default: return e.channel.id == filter;
            }
        }

        private void rebuild_list () {
            var entries = new Gee.ArrayList<Entry> ();
            var seen = new Gee.HashSet<string> ();
            foreach (var e in engine.entries (null, query)) {
                if (!accepts (e)) continue;
                entries.add (e);
                seen.add (e.key);
            }
            if (query.length >= 2) {
                foreach (var e in engine.search_messages (query)) {
                    if (!seen.contains (e.key) && accepts (e)) {
                        entries.add (e);
                        seen.add (e.key);
                    }
                }
            }
            updating_selection = true;
            Widget? child;
            while ((child = list.get_first_child ()) != null) list.remove (child);
            rows.clear ();
            foreach (var e in entries) {
                var row = new ConversationRow ();
                row.bind (e, app.avatars.lookup (e.channel, e.conversation));
                list.append (row);
                rows[e.key] = row;
                if (open_channel != null && e.channel == open_channel && e.conversation.id == open_conversation) list.select_row (row);
            }
            updating_selection = false;
            if (entries.size == 0) {
                list_stack.visible_child_name = "empty";
                if (query != "") {
                    list_empty.title = _("No Results");
                    list_empty.description = _("No conversation matches \"%s\".").printf (query);
                } else if (filter == "unread") {
                    list_empty.title = _("All Caught Up");
                    list_empty.description = _("There are no unread conversations.");
                } else {
                    list_empty.title = _("No Conversations Yet");
                    list_empty.description = _("Conversations appear here as soon as your accounts load them.");
                }
            } else {
                list_stack.visible_child_name = "list";
            }
        }

        public void open_entry (Channel ch, string conversation) {
            if (open_channel == ch && open_conversation == conversation) {
                sync_focus ();
                return;
            }
            open_channel = ch;
            open_conversation = conversation;
            composer.clear_context ();
            composer.set_text (app.drafts_take (Engine.key_of (ch.id, conversation)));
            var c = engine.find_conversation (ch.id, conversation);
            composer.set_features (ch.features, c != null && c.read_only);
            chat_stack.visible_child_name = "chat";
            update_head ();
            rebuild_thread ();
            scroll_to_end ();
            engine.load.begin (ch, conversation);
            sync_focus ();
            app.notifier.withdraw (Engine.key_of (ch.id, conversation));
            Idle.add (() => {
                composer.focus_entry ();
                return Source.REMOVE;
            });
            var row = rows[Engine.key_of (ch.id, conversation)];
            if (row != null && list.get_selected_row () != row) {
                updating_selection = true;
                list.select_row (row);
                updating_selection = false;
            }
        }

        public void open_by_id (string channel, string conversation) {
            var ch = engine.channel (channel);
            if (ch == null) return;
            if (filter != "all" && filter != channel) {
                filter = "all";
                foreach (var e in nav_rows.entries) e.value.set_active (e.key == filter);
                queue_rebuild ();
            }
            open_entry (ch, conversation);
        }

        private void update_head () {
            if (open_channel == null) return;
            var c = engine.find_conversation (open_channel.id, open_conversation);
            string title = c != null && c.title != "" ? c.title : _("Conversation");
            head_title.label = title;
            head_subtitle.label = open_channel.title;
            head_avatar.set_person (title, c != null ? app.avatars.lookup (open_channel, c) : null, c != null && c.kind != ConversationKind.DIRECT);
            set_title ("%s - %s".printf (title, _("Messages")));
        }

        private void sync_focus () {
            if (open_channel == null) {
                engine.focus ("", "", false);
                return;
            }
            engine.focus (open_channel.id, open_conversation, is_active && visible);
        }

        private void scroll_to_end () {
            stick_bottom = true;
            int frames = 0;
            thread_scroll.add_tick_callback ((widget, clock) => {
                var adj = thread_scroll.vadjustment;
                adj.value = adj.upper - adj.page_size;
                stick_bottom = true;
                return ++frames < 12 ? Source.CONTINUE : Source.REMOVE;
            });
        }

        private void rebuild_thread () {
            if (open_channel == null) return;
            Widget? child;
            while ((child = thread.get_first_child ()) != null) thread.remove (child);
            var c = engine.find_conversation (open_channel.id, open_conversation);
            bool group = c != null && c.kind != ConversationKind.DIRECT;
            string last_day = "";
            string last_author = "";
            int64 last_time = 0;
            foreach (var m in engine.messages (open_channel.id, open_conversation)) {
                string day = m.time > 0 ? new DateTime.from_unix_local (m.time).format ("%Y%j") : "";
                if (day != "" && day != last_day) {
                    thread.append (new DayRow (m.time));
                    last_day = day;
                    last_author = "";
                }
                bool show_author = m.system || m.author_id != last_author || m.time - last_time > 300;
                last_author = m.system ? "" : m.author_id;
                last_time = m.time;
                var row = new MessageRow (m, show_author, group, null);
                var msg = m;
                row.react.connect ((emoji) => engine.react.begin (open_channel, open_conversation, msg, emoji));
                row.open_attachment.connect ((a) => open_attachment.begin (a));
                row.retry.connect (() => engine.retry (open_channel, open_conversation, msg));
                thread.append (row);
            }
        }

        private void message_menu (MessageRow row, double x, double y) {
            if (open_channel == null || row.message.system) return;
            var m = row.message;
            var ch = open_channel;
            string conv = open_conversation;
            var menu = new ContextMenu (row);
            if (!m.deleted && ch.supports (Features.REPLIES) && m.state == MessageState.SENT) menu.add_item (_("Reply"), "mail-reply-sender-symbolic", () => composer.reply_to (m));
            if (!m.deleted && ch.supports (Features.REACTIONS) && m.state == MessageState.SENT) {
                var react = menu.add_submenu (_("React"), "face-smile-symbolic");
                foreach (string e in new string[] { "👍", "❤️", "😂", "😮", "😢", "🎉" }) {
                    string emoji = e;
                    react.add_item (emoji, null, () => engine.react.begin (ch, conv, m, emoji));
                }
            }
            if (m.text != "" && !m.deleted) {
                menu.add_item (_("Copy Text"), "edit-copy-symbolic", () => get_clipboard ().set_text (m.text));
            }
            if (m.outgoing && !m.deleted && m.state == MessageState.SENT) {
                if (ch.supports (Features.EDIT) && m.attachments.size == 0) menu.add_item (_("Edit"), "document-edit-symbolic", () => composer.edit (m));
                if (ch.supports (Features.DELETE)) {
                    menu.add_separator ();
                    menu.add_item (_("Delete for Everyone"), "user-trash-symbolic", () => engine.remove.begin (ch, conv, m), "destructive");
                }
            }
            if (m.state == MessageState.FAILED) {
                menu.add_item (_("Try Again"), "view-refresh-symbolic", () => engine.retry (ch, conv, m));
                menu.add_item (_("Discard"), "user-trash-symbolic", () => engine.discard (ch, conv, m), "destructive");
            }
            Graphene.Point p;
            if (thread.compute_point (row, Graphene.Point () { x = (float) x, y = (float) y }, out p)) {
                Gdk.Rectangle r = { (int) p.x, (int) p.y, 1, 1 };
                menu.pointing_to = r;
            }
            menu.popup ();
        }

        private void conversation_menu (ConversationRow row) {
            var e = row.entry;
            var menu = new ContextMenu (row);
            if (e.conversation.unread > 0) menu.add_item (_("Mark as Read"), "mail-read-symbolic", () => engine.mark_read.begin (e.channel, e.conversation.id));
            menu.add_item (_("Open in New Window"), "window-new-symbolic", () => {
                var w = new MessagesWindow (app);
                w.present ();
                w.open_entry (e.channel, e.conversation.id);
            });
            menu.popup ();
        }

        private void pick_files () {
            if (open_channel == null || !open_channel.supports (Features.ATTACHMENTS)) return;
            var ch = open_channel;
            string conv = open_conversation;
            var dialog = new FileDialog ();
            dialog.title = _("Send Files");
            dialog.open_multiple.begin (this, null, (o, res) => {
                try {
                    var files = dialog.open_multiple.end (res);
                    for (uint i = 0; i < files.get_n_items (); i++) {
                        var f = (File) files.get_item (i);
                        show_toast (_("Sending %s…").printf (f.get_basename ()));
                        engine.upload.begin (ch, conv, f, "");
                    }
                } catch (Error e) {
                }
            });
        }

        private async void open_attachment (Attachment a) {
            if (open_channel == null) return;
            if (a.path != "" && FileUtils.test (a.path, FileTest.EXISTS)) {
                launch (File.new_for_path (a.path));
                return;
            }
            if (a.url.has_prefix ("http") && !a.url.contains ("/remote.php/") && !a.url.contains ("googleapis.com") && !a.url.contains ("graph.microsoft.com")) {
                launch (File.new_for_uri (a.url));
                return;
            }
            show_toast (_("Downloading %s…").printf (a.name));
            try {
                var bytes = yield open_channel.download (a);
                if (bytes == null) {
                    if (a.url != "") launch (File.new_for_uri (a.url));
                    return;
                }
                string dir = Path.build_filename (Environment.get_user_cache_dir (), "singularity", "messages", "files");
                DirUtils.create_with_parents (dir, 0700);
                string name = a.name != "" ? a.name.replace ("/", "_") : "attachment";
                string path = Path.build_filename (dir, name);
                FileUtils.set_data (path, bytes.get_data ());
                a.path = path;
                launch (File.new_for_path (path));
            } catch (Error e) {
                show_toast (e.message);
            }
        }

        private void launch (File f) {
            var launcher = new FileLauncher (f);
            launcher.launch.begin (this, null, (o, res) => {
                try {
                    launcher.launch.end (res);
                } catch (Error e) {
                    show_toast (e.message);
                }
            });
        }

        public void new_conversation (string query = "") {
            var d = new NewConversationDialog (app, this, engine, query);
            d.started.connect ((ch, id) => open_by_id (ch.id, id));
            d.open_dialog ();
        }

        public void prefill (string text) {
            composer.set_text (text);
            composer.focus_entry ();
        }

        public void save_draft () {
            if (open_channel == null) return;
            app.drafts_put (Engine.key_of (open_channel.id, open_conversation), composer.text ());
        }

        public void show_toast (string text) {
            if (last_toast != null) last_toast.dismiss ();
            last_toast = new Singularity.Widgets.Toast (text);
            add_toast (last_toast);
        }

        public override bool close_request () {
            save_draft ();
            engine.focus ("", "", false);
            return base.close_request ();
        }
    }
}
