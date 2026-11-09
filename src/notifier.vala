using Singularity.Messaging;

namespace Singularity.Apps.Messages {

    public class Avatars : Object {
        private const int64 MAX_AGE = 3 * TimeSpan.DAY;

        private string dir;
        private Gee.HashSet<string> pending = new Gee.HashSet<string> ();
        private Gee.HashSet<string> missing = new Gee.HashSet<string> ();
        private Gee.HashSet<string> composing = new Gee.HashSet<string> ();
        private Gee.HashMap<string, int64?> checked = new Gee.HashMap<string, int64?> ();
        private const int64 RECHECK = 60 * TimeSpan.SECOND;

        public signal void ready (string key);

        public Avatars (Store store) {
            dir = Path.build_filename (store.cache_dir (), "avatars");
            DirUtils.create_with_parents (dir, 0700);
        }

        private string path_for (string url) {
            return Path.build_filename (dir, Store.safe (url) + ".img");
        }

        public static string author_key (Channel ch) {
            return "author\n" + ch.id;
        }

        public string? lookup_author (Channel ch, string author_id) {
            string url = "";
            var teams = ch as TeamsChannel;
            if (teams != null) url = teams.photo_url (author_id);
            var talk = ch as TalkChannel;
            if (talk != null) url = talk.avatar_of (author_id);
            return url != "" ? lookup_url (ch, url, author_key (ch)) : null;
        }

        public string? lookup (Channel ch, Conversation c) {
            if (c.avatar_url == "") return null;
            return lookup_url (ch, c.avatar_url, Engine.key_of (ch.id, c.id));
        }

        private string? lookup_group (Channel ch, string url, string key) {
            string group_path = path_for (url);
            int64? fresh = checked[group_path];
            if (fresh != null && GLib.get_monotonic_time () - fresh < RECHECK) return group_path;
            string[] paths = {};
            int64 newest = 0;
            foreach (string part in url.substring (GroupAvatar.PREFIX.length).split ("\n")) {
                if (part == "") continue;
                string? p = lookup_url (ch, part, key);
                if (p == null) continue;
                paths += p;
                newest = int64.max (newest, modified (p));
            }
            if (paths.length == 0) return null;
            if (paths.length == 1) return paths[0];
            string path = group_path;
            if (FileUtils.test (path, FileTest.EXISTS) && modified (path) >= newest) {
                checked[path] = GLib.get_monotonic_time ();
                return path;
            }
            compose.begin (paths, path, key);
            return paths[0];
        }

        private async void compose (string[] paths, string path, string key) {
            if (composing.contains (path)) return;
            composing.add (path);
            string[] parts = paths;
            try {
                yield Singularity.Async.run<bool> ((c) => {
                    GroupAvatar.compose (parts, path);
                    return true;
                }, Singularity.Async.Qos.UTILITY);
                checked.unset (path);
                ready (key);
            } catch (Error e) {
            }
            composing.remove (path);
        }

        private static int64 modified (string path) {
            try {
                var info = File.new_for_path (path).query_info (FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                return (int64) info.get_attribute_uint64 (FileAttribute.TIME_MODIFIED);
            } catch (Error e) {
                return 0;
            }
        }

        private string? lookup_url (Channel ch, string url, string key) {
            if (url.has_prefix (GroupAvatar.PREFIX)) return lookup_group (ch, url, key);
            string path = path_for (url);
            int64 now = GLib.get_monotonic_time ();
            int64? seen = checked[path];
            if (seen != null && now - seen < RECHECK) return path;
            if (FileUtils.test (path, FileTest.EXISTS)) {
                checked[path] = now;
                try {
                    var info = File.new_for_path (path).query_info (FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                    var mod = info.get_modification_date_time ();
                    if (mod != null && new DateTime.now_utc ().difference (mod) > MAX_AGE) fetch.begin (ch, url, key);
                } catch (Error e) {
                }
                return path;
            }
            fetch.begin (ch, url, key);
            return null;
        }

        private async void fetch (Channel ch, string url, string key) {
            if (pending.contains (url) || missing.contains (url)) return;
            pending.add (url);
            try {
                var a = new Attachment ();
                a.url = url;
                var bytes = yield ch.download (a);
                if (bytes != null && bytes.get_size () > 0) {
                    FileUtils.set_data (path_for (url), bytes.get_data ());
                    ready (key);
                } else {
                    missing.add (url);
                }
            } catch (Error e) {
                missing.add (url);
            }
            pending.remove (url);
        }
    }

    public delegate void NotificationActivated (string action);
    public delegate void NotificationReplied (string text);

    public class Notifier : Object {
        private const string BUS = "org.freedesktop.Notifications";
        private const string PATH = "/org/freedesktop/Notifications";

        private class Handlers {
            public NotificationActivated? on_action;
            public NotificationReplied? on_reply;
            public string key;
        }

        private DBusConnection? bus = null;
        private Gee.HashMap<uint32, Handlers> handlers = new Gee.HashMap<uint32, Handlers> ();
        private Gee.HashMap<string, uint32> by_key = new Gee.HashMap<string, uint32> ();
        private Gee.HashMap<string, Gee.ArrayList<string>> lines = new Gee.HashMap<string, Gee.ArrayList<string>> ();

        public Notifier () {
            try {
                bus = Bus.get_sync (BusType.SESSION);
                bus.signal_subscribe (null, BUS, null, PATH, null, DBusSignalFlags.NONE, on_signal);
            } catch (Error e) {
                warning ("messages: %s", e.message);
            }
        }

        private void on_signal (DBusConnection conn, string? sender, string path, string iface, string name, Variant parameters) {
            if (name == "ActionInvoked") {
                uint32 id;
                string key;
                parameters.get ("(us)", out id, out key);
                var h = handlers[id];
                if (h != null && h.on_action != null) h.on_action (key);
            } else if (name == "NotificationReplied") {
                uint32 id;
                string text;
                parameters.get ("(us)", out id, out text);
                var h = handlers[id];
                if (h != null && h.on_reply != null) h.on_reply (text);
            } else if (name == "NotificationClosed") {
                uint32 id;
                uint32 reason;
                parameters.get ("(uu)", out id, out reason);
                var h = handlers[id];
                handlers.unset (id);
                if (h != null && by_key[h.key] == id) {
                    by_key.unset (h.key);
                    lines.unset (h.key);
                }
            }
        }

        public async void show (string key, string summary, string body, string? image, string message_id, owned NotificationActivated on_action, owned NotificationReplied on_reply) {
            if (bus == null) return;
            var past = lines[key];
            if (past == null) {
                past = new Gee.ArrayList<string> ();
                lines[key] = past;
            }
            past.add (body);
            while (past.size > 4) past.remove_at (0);
            var hints = new VariantBuilder (new VariantType ("a{sv}"));
            hints.add ("{sv}", "desktop-entry", new Variant.string ("dev.sinty.messages"));
            hints.add ("{sv}", "category", new Variant.string ("im.received"));
            hints.add ("{sv}", "x-kde-reply-placeholder-text", new Variant.string (_("Reply")));
            if (image != null) hints.add ("{sv}", "image-path", new Variant.string (image));
            if (message_id != "") hints.add ("{sv}", "x-sinty-message-id", new Variant.string (message_id));
            hints.add ("{sv}", "x-sinty-message-text", new Variant.string (body));
            string[] actions = { "default", _("Open"), "inline-reply", _("Reply"), "read", _("Mark as Read") };
            uint32 replaces = by_key.has_key (key) ? by_key[key] : 0;
            try {
                var reply = yield bus.call (BUS, PATH, BUS, "Notify",
                    new Variant ("(susss^as@a{sv}i)", _("Messages"), replaces, image ?? "dev.sinty.messages", summary, string.joinv ("\n", past.to_array ()), actions, hints.end (), -1),
                    new VariantType ("(u)"), DBusCallFlags.NONE, 5000, null);
                uint32 id;
                reply.get ("(u)", out id);
                var h = new Handlers ();
                h.on_action = (owned) on_action;
                h.on_reply = (owned) on_reply;
                h.key = key;
                if (replaces != 0 && replaces != id) handlers.unset (replaces);
                handlers[id] = h;
                by_key[key] = id;
            } catch (Error e) {
                debug ("messages: no notification server: %s", e.message);
            }
        }

        public void withdraw (string key) {
            if (bus == null || !by_key.has_key (key)) return;
            uint32 id = by_key[key];
            by_key.unset (key);
            lines.unset (key);
            handlers.unset (id);
            bus.call.begin (BUS, PATH, BUS, "CloseNotification", new Variant ("(u)", id), null, DBusCallFlags.NONE, 5000, null);
        }

        public void badge (int count) {
            if (bus == null) return;
            var props = new VariantBuilder (new VariantType ("a{sv}"));
            props.add ("{sv}", "count", new Variant.int64 (count));
            props.add ("{sv}", "count-visible", new Variant.boolean (count > 0));
            try {
                bus.emit_signal (null, "/dev/sinty/messages/launcher", "com.canonical.Unity.LauncherEntry", "Update",
                    new Variant ("(s@a{sv})", "application://dev.sinty.messages.desktop", props.end ()));
            } catch (Error e) {
                debug ("messages: %s", e.message);
            }
        }
    }
}
