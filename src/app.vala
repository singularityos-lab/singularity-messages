using Gtk;
using Singularity.Messaging;

namespace Singularity.Apps.Messages {

    [DBus (name = "dev.sinty.Messages1")]
    public class MessagesBus : Object {
        private unowned MessagesApp app;

        public MessagesBus (MessagesApp app) {
            this.app = app;
        }

        public void open_conversation (string channel, string conversation) throws Error {
            app.show_conversation (channel, conversation);
        }

        public void compose (string person, string address, string text) throws Error {
            app.compose (person, address, text);
        }

        public async void send (string channel, string conversation, string text) throws Error {
            app.hold ();
            var ch = app.engine.channel (channel);
            if (ch == null) {
                yield app.engine.discover ();
                ch = app.engine.channel (channel);
            }
            if (ch == null) {
                app.release ();
                throw new MessagingError.NOT_FOUND ("unknown account");
            }
            if (app.engine.find_conversation (channel, conversation) == null) yield app.engine.start (ch, conversation);
            yield app.engine.send (ch, conversation, text, null);
            app.release ();
        }

        public int unread_count () throws Error {
            return app.engine.unread_total ();
        }
    }

    [DBus (name = "dev.sinty.Collab.Message1")]
    public class MessageCollabBus : Object {
        private unowned MessagesApp app;

        public MessageCollabBus (MessagesApp app) {
            this.app = app;
        }

        public void receive (string person, string payload, string from) throws Error {
            app.receive_nearby (person, payload, from);
        }

        public void join (string session, string title, string snapshot, string role, string from) throws Error {
            throw new IOError.NOT_SUPPORTED ("messages are not shared in a session");
        }
    }

    public class MessagesApp : Singularity.Application {
        public Store store;
        public Engine engine;
        public Avatars avatars;
        public Notifier notifier;
        public Singularity.AppPluginHost plugins;
        private Gee.HashMap<string, string> drafts = new Gee.HashMap<string, string> ();
        private Gee.HashMap<string, Provider> plugin_providers = new Gee.HashMap<string, Provider> ();
        private uint bus_id = 0;
        private uint collab_id = 0;
        private bool started_engine = false;
        private string? pending_action = null;

        public MessagesApp () {
            Object (application_id: "dev.sinty.messages", flags: ApplicationFlags.HANDLES_OPEN);
            add_main_option ("new-conversation", 0, OptionFlags.NONE, OptionArg.NONE, _("Start a new conversation"), null);
            new MessagesSearchProvider (this).export (this);
        }

        protected override int handle_local_options (VariantDict options) {
            if (!options.contains ("new-conversation")) return -1;
            try {
                register (null);
            } catch (Error e) {
                warning ("messages: %s", e.message);
                return 1;
            }
            if (get_is_remote ()) {
                activate_action ("new-conversation", null);
                return 0;
            }
            pending_action = "new-conversation";
            return -1;
        }

        public override bool dbus_register (DBusConnection connection, string object_path) throws Error {
            if (!base.dbus_register (connection, object_path)) return false;
            bus_id = connection.register_object ("/dev/sinty/messages/Messages", new MessagesBus (this));
            collab_id = connection.register_object ("/dev/sinty/messages/Collab", new MessageCollabBus (this));
            return true;
        }

        public override void dbus_unregister (DBusConnection connection, string object_path) {
            if (bus_id != 0) connection.unregister_object (bus_id);
            if (collab_id != 0) connection.unregister_object (collab_id);
            bus_id = collab_id = 0;
            base.dbus_unregister (connection, object_path);
        }

        protected override void startup () {
            base.startup ();
            store = new Store ();
            engine = new Engine (store);
            avatars = new Avatars (store);
            notifier = new Notifier ();
            load_drafts ();
            var provider = new CssProvider ();
            provider.load_from_string (CSS);
            StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider, STYLE_PROVIDER_PRIORITY_USER + 1);
            build_menu ();
            install_actions ();
            engine.arrived.connect (on_arrived);
            engine.conversations_changed.connect (() => notifier.badge (engine.unread_total ()));
            if ((flags & ApplicationFlags.IS_SERVICE) != 0) inactivity_timeout = 30000;
            start_engine ();
        }

        private void start_engine () {
            if (started_engine) return;
            started_engine = true;
            engine.add_provider (new TalkProvider ());
            engine.add_provider (new GoogleChatProvider ());
            engine.add_provider (new TeamsProvider ());
            engine.add_provider (new SmsProvider ());
            engine.add_provider (new NearbyPeersProvider ());
            engine.add_provider (new SocketProvider ());
            engine.add_provider (new GroupsProvider (engine));
            plugins = new Singularity.AppPluginHost ("dev.sinty.messages", "messages", Singularity.AppPluginHost.desktop_settings ());
            plugins.add_extension_type (typeof (Provider));
            plugins.extension_added.connect ((info, ext) => {
                var p = ext as Provider;
                if (p == null) return;
                plugin_providers[info.get_module_name ()] = p;
                engine.add_provider (p);
                engine.discover.begin ();
            });
            plugins.extension_removed.connect ((info, ext) => {
                var p = ext as Provider;
                if (p == null) return;
                plugin_providers.unset (info.get_module_name ());
                engine.remove_provider (p);
            });
            plugins.load ();
            var accounts = Singularity.Accounts.Manager.get_default ();
            accounts.account_added.connect (() => engine.discover.begin ());
            accounts.account_removed.connect (() => engine.discover.begin ());
            accounts.account_changed.connect (() => engine.discover.begin ());
            accounts.reloaded.connect (() => engine.discover.begin ());
            if (Singularity.Collab.Client.installed ()) Singularity.Collab.Client.get_default ().refresh_people.begin ();
            accounts.load.begin ((o, res) => {
                accounts.load.end (res);
                engine.discover.begin ();
            });
        }

        private void build_menu () {
            var menu = new GLib.Menu ();
            var file = new GLib.Menu ();
            var f1 = new GLib.Menu ();
            f1.append (_("New Conversation"), "win.new-conversation");
            f1.append (_("New Group"), "win.new-group");
            f1.append (_("Send a File…"), "win.attach");
            file.append_section (null, f1);
            var f2 = new GLib.Menu ();
            f2.append (_("Online Accounts…"), "app.accounts");
            file.append_section (null, f2);
            var f3 = new GLib.Menu ();
            f3.append (_("Close Window"), "win.close");
            f3.append (_("Quit"), "app.quit");
            file.append_section (null, f3);
            menu.append_submenu (_("File"), file);
            var edit = new GLib.Menu ();
            var e1 = new GLib.Menu ();
            e1.append (_("Search"), "win.find");
            e1.append (_("Mark All as Read"), "win.mark-all-read");
            edit.append_section (null, e1);
            menu.append_submenu (_("Edit"), edit);
            var view = new GLib.Menu ();
            var v1 = new GLib.Menu ();
            v1.append (_("Next Conversation"), "win.next-conversation");
            v1.append (_("Previous Conversation"), "win.previous-conversation");
            view.append_section (null, v1);
            var v2 = new GLib.Menu ();
            v2.append (_("Refresh"), "win.refresh");
            view.append_section (null, v2);
            menu.append_submenu (_("View"), view);
            set_menubar (menu);
        }

        private void install_actions () {
            var quit_action = new SimpleAction ("quit", null);
            quit_action.activate.connect (() => {
                foreach (var w in get_windows ().copy ()) w.close ();
                quit ();
            });
            add_action (quit_action);
            var accounts_action = new SimpleAction ("accounts", null);
            accounts_action.activate.connect (() => open_accounts ());
            add_action (accounts_action);
            var new_conv = new SimpleAction ("new-conversation", null);
            new_conv.activate.connect (() => window ().new_conversation ());
            add_action (new_conv);
            var open_conv = new SimpleAction ("open-conversation", new VariantType ("(ss)"));
            open_conv.activate.connect ((p) => {
                string ch, conv;
                p.get ("(ss)", out ch, out conv);
                show_conversation (ch, conv);
            });
            add_action (open_conv);
            var share_text = new SimpleAction ("share-text", VariantType.STRING);
            share_text.activate.connect ((p) => compose ("", "", p.get_string ()));
            add_action (share_text);
            var share_files = new SimpleAction ("share-files", new VariantType ("as"));
            share_files.activate.connect ((p) => {
                string[] uris = p.dup_strv ();
                compose ("", "", string.joinv ("\n", uris));
            });
            add_action (share_files);
            set_accels_for_action ("win.new-conversation", { "<Control>n" });
            set_accels_for_action ("win.refresh", { "<Control>r", "F5" });
            set_accels_for_action ("win.find", { "<Control>f", "<Control>k" });
            set_accels_for_action ("win.next-conversation", { "<Alt>Down", "<Control>Tab" });
            set_accels_for_action ("win.previous-conversation", { "<Alt>Up", "<Control><Shift>Tab" });
            set_accels_for_action ("win.attach", { "<Control><Shift>a" });
            set_accels_for_action ("win.close", { "<Control>w" });
            set_accels_for_action ("app.quit", { "<Control>q" });
        }

        public MessagesWindow window () {
            var w = active_window as MessagesWindow;
            if (w == null) {
                foreach (var win in get_windows ()) {
                    w = win as MessagesWindow;
                    if (w != null) break;
                }
            }
            if (w == null) w = new MessagesWindow (this);
            return w;
        }

        protected override void activate () {
            var w = window ();
            w.present ();
            if (pending_action == "new-conversation") {
                pending_action = null;
                w.new_conversation ();
            }
        }

        protected override void open (File[] files, string hint) {
            var w = window ();
            w.present ();
            foreach (var f in files) {
                string uri = f.get_uri ();
                if (uri.has_prefix ("sinty-messages:")) {
                    string[] parts = uri.substring (15).split ("/", 2);
                    if (parts.length == 2) show_conversation (Uri.unescape_string (parts[0]) ?? parts[0], Uri.unescape_string (parts[1]) ?? parts[1]);
                }
            }
        }

        public void show_conversation (string channel, string conversation) {
            var w = window ();
            w.present ();
            if (engine.channel (channel) != null) {
                w.open_by_id (channel, conversation);
                return;
            }
            ulong id = 0;
            id = engine.channels_changed.connect (() => {
                if (engine.channel (channel) == null) return;
                engine.disconnect (id);
                w.open_by_id (channel, conversation);
            });
        }

        public void compose (string person, string address, string text) {
            var w = window ();
            w.present ();
            string target = address != "" ? address : person;
            if (target != "") {
                foreach (var e in engine.entries ()) {
                    var c = e.conversation;
                    if (c.kind != ConversationKind.DIRECT) continue;
                    if ((address != "" && c.peer.down () == address.down ()) || (person != "" && c.title.down () == person.down ())) {
                        w.open_entry (e.channel, c.id);
                        if (text != "") w.prefill (text);
                        return;
                    }
                }
            }
            w.new_conversation (target);
            if (text != "") drafts_put ("compose", text);
        }

        public void receive_nearby (string person, string payload, string from) {
            hold ();
            engine.discover.begin ((o, res) => {
                engine.discover.end (res);
                var ch = NearbyPeersProvider.instance;
                if (ch != null) ch.receive (person, from, payload);
                release ();
            });
        }

        private void on_arrived (Channel ch, Conversation c, Message m) {
            if (c.muted || (c.mentions_only && !c.mentioned)) return;
            string key = Engine.key_of (ch.id, c.id);
            string summary = c.kind == ConversationKind.DIRECT || m.author_name == "" ? c.title : "%s · %s".printf (m.author_name, c.title);
            string body = m.preview ();
            if (body == "") return;
            string ch_id = ch.id;
            string conv = c.id;
            notifier.show.begin (key, summary, body, avatars.lookup (ch, c), (action) => {
                if (action == "read") {
                    var channel = engine.channel (ch_id);
                    if (channel != null) engine.mark_read.begin (channel, conv);
                    notifier.withdraw (key);
                    return;
                }
                show_conversation (ch_id, conv);
            }, (text) => {
                var channel = engine.channel (ch_id);
                if (channel == null || text.strip () == "") return;
                hold ();
                engine.send.begin (channel, conv, text.strip (), null, (o, res) => {
                    engine.send.end (res);
                    engine.mark_read.begin (channel, conv);
                    notifier.withdraw (key);
                    release ();
                });
            });
        }

        public void open_accounts () {
            try {
                Singularity.Shell.ShellService shell = Bus.get_proxy_sync (BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                shell.open_settings ("accounts");
            } catch (Error e) {
                warning ("messages: cannot open Settings: %s", e.message);
            }
        }

        private string drafts_path () {
            return Path.build_filename (store.root, "drafts.json");
        }

        private void load_drafts () {
            string text;
            try {
                if (!FileUtils.get_contents (drafts_path (), out text)) return;
                var parser = new Json.Parser ();
                parser.load_from_data (text);
                var o = parser.get_root ().get_object ();
                foreach (string k in o.get_members ()) drafts[k] = o.get_string_member (k);
            } catch (Error e) {
            }
        }

        public string drafts_take (string key) {
            string? d = drafts[key];
            if (d == null && drafts.has_key ("compose")) {
                d = drafts["compose"];
                drafts.unset ("compose");
            }
            return d ?? "";
        }

        public void drafts_put (string key, string text) {
            if (text.strip () == "") drafts.unset (key);
            else drafts[key] = text;
            var o = new Json.Object ();
            foreach (var e in drafts.entries) o.set_string_member (e.key, e.value);
            Store.write_json (drafts_path (), o);
        }

        protected override void shutdown () {
            foreach (var w in get_windows ()) {
                var mw = w as MessagesWindow;
                if (mw != null) mw.save_draft ();
            }
            engine.shutdown ();
            base.shutdown ();
        }

        private const string CSS = """
.messages-list row.messages-conversation-row { border-radius: 10px; margin: 1px 6px; }
.messages-list row.messages-conversation-row.unread .messages-row-title { font-weight: 700; }
.messages-list row.messages-conversation-row:selected { background: alpha(@accent_bg_color, 0.18); color: inherit; }
.messages-list { background: transparent; }
.messages-service-badge { background: @window_bg_color; border-radius: 999px; padding: 2px; -gtk-icon-size: 12px; }
.messages-unread, .messages-nav-count { background: @accent_bg_color; color: @accent_fg_color; border-radius: 999px; padding: 0 6px; min-width: 10px; font-size: 0.8em; font-weight: 700; }
.messages-nav-count { margin-left: 6px; }
.messages-unread.quiet { background: alpha(currentColor, 0.18); color: inherit; }
.messages-chat-head { padding: 8px 14px; border-bottom: 1px solid alpha(currentColor, 0.08); }
.messages-thread { background: transparent; padding-bottom: 8px; }
.messages-thread row, .messages-thread row:hover { background: transparent; }
.messages-day { font-size: 0.82em; font-weight: 600; opacity: 0.6; }
.messages-system { font-size: 0.85em; opacity: 0.6; }
.messages-author { font-size: 0.82em; font-weight: 600; opacity: 0.75; }
.messages-bubble { padding: 7px 11px 5px 11px; border-radius: 16px; }
.messages-bubble.incoming { background: alpha(currentColor, 0.08); border-bottom-left-radius: 5px; }
.messages-bubble.outgoing { background: @accent_bg_color; color: @accent_fg_color; border-bottom-right-radius: 5px; }
.messages-bubble.deleted { opacity: 0.6; font-style: italic; }
.messages-meta { font-size: 0.75em; opacity: 0.7; }
.messages-quote { border-left: 3px solid alpha(currentColor, 0.5); padding-left: 6px; font-size: 0.88em; opacity: 0.85; }
.messages-attachment { padding: 6px 8px; border-radius: 10px; background: alpha(currentColor, 0.06); }
.messages-reaction { padding: 0 8px; min-height: 22px; border-radius: 999px; font-size: 0.85em; }
.messages-reaction:checked { background: alpha(@accent_bg_color, 0.25); color: inherit; }
.messages-retry { font-size: 0.85em; color: @error_color; padding: 0 6px; min-height: 20px; }
.messages-composer { border-top: 1px solid alpha(currentColor, 0.08); padding: 8px 12px 10px 12px; }
.messages-composer-tray { padding: 2px 4px 8px 4px; }
.messages-composer-chip { border-radius: 10px; background: alpha(currentColor, 0.06); }
.messages-composer-chip picture { border-radius: 10px; }
.messages-composer-remove { margin: 4px; min-width: 22px; min-height: 22px; padding: 0; background: rgba(0, 0, 0, 0.6); color: white; box-shadow: none; }
.messages-composer-remove:hover { background: rgba(0, 0, 0, 0.8); }
.messages-composer-remove image { color: white; }
.messages-composer-context { padding: 2px 4px 8px 4px; font-size: 0.9em; }
.messages-entry { background: alpha(currentColor, 0.06); border-radius: 18px; padding-right: 4px; }
.messages-entry-view, .messages-entry-view text { background: transparent; }
.messages-entry scrolledwindow, .messages-entry scrolledwindow:focus-within, .messages-entry textview, .messages-entry textview:focus, .messages-entry textview:focus-visible, .messages-entry textview > text, .messages-entry textview > text:focus, .messages-entry textview > text:focus-visible { outline: none; outline-width: 0; box-shadow: none; border: none; }
.messages-entry:focus-within { box-shadow: inset 0 0 0 2px alpha(@accent_bg_color, 0.55); }
""";
    }

    public static int main (string[] args) {
        Intl.setlocale (LocaleCategory.ALL, "");
        string locale_dir = "/usr/share/locale";
        try {
            string exe = FileUtils.read_link ("/proc/self/exe");
            locale_dir = Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "share", "locale");
        } catch (Error e) {
        }
        Intl.bindtextdomain ("singularity-messages", locale_dir);
        Intl.bind_textdomain_codeset ("singularity-messages", "UTF-8");
        Intl.textdomain ("singularity-messages");
        return new MessagesApp ().run (args);
    }
}
