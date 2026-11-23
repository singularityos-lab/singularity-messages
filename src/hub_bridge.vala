using Singularity.Messaging;

namespace Singularity.Apps.Messages {

    public class HubBridge : Object {
        private const int LIMIT = 40;
        private const int BODY_MESSAGES = 12;
        private const string PREFIX = "messages:";

        private unowned MessagesApp app;
        private Gee.HashMap<string, Gee.HashSet<string>> published = new Gee.HashMap<string, Gee.HashSet<string>> ();
        private Gee.HashMap<string, int64?> hidden = new Gee.HashMap<string, int64?> ();
        private uint flush_source = 0;

        public HubBridge (MessagesApp app) {
            this.app = app;
            Singularity.Hub.install_action (app, on_action);
            app.engine.conversations_changed.connect (queue_flush);
            app.engine.channels_changed.connect (queue_flush);
            app.engine.messages_changed.connect (() => queue_flush ());
            Bus.watch_name (BusType.SESSION, Singularity.Hub.BUS_NAME, BusNameWatcherFlags.NONE, () => queue_flush (), null);
        }

        private static string hub_account (Channel ch) {
            return PREFIX + ch.id;
        }

        private static bool is_text (Channel ch) {
            return ch.provider_id == "sms" || ch.provider_id == "modem";
        }

        private void queue_flush () {
            if (flush_source != 0) return;
            flush_source = Timeout.add (300, () => {
                flush_source = 0;
                publish_all ();
                return Source.REMOVE;
            });
        }

        private void publish_all () {
            var seen = new Gee.HashSet<string> ();
            foreach (var ch in app.engine.get_channels ()) {
                seen.add (ch.id);
                publish_channel (ch);
            }
            foreach (var id in published.keys.to_array ()) {
                if (seen.contains (id)) continue;
                foreach (var item in published[id]) Singularity.Hub.withdraw (PREFIX + id, item);
                published.unset (id);
            }
        }

        private void publish_channel (Channel ch) {
            bool text = is_text (ch);
            var account = new Singularity.Hub.Account (hub_account (ch), ch.title != "" ? ch.title : _("Messages"),
                text ? Singularity.Hub.AccountKind.TEXT : Singularity.Hub.AccountKind.MESSAGING);
            account.icon_name = text ? "mail-message-new-symbolic" : ch.icon_name;
            account.app_id = "dev.sinty.messages";
            Singularity.Hub.register_account (account);

            var keep = new Gee.HashSet<string> ();
            int n = 0;
            foreach (var entry in app.engine.entries (ch.id)) {
                if (n++ >= LIMIT) break;
                var c = entry.conversation;
                if (c.activity <= 0) continue;
                string key = ch.id + "\n" + c.id;
                if (hidden.has_key (key) && hidden[key] >= c.activity) continue;
                hidden.unset (key);
                keep.add (c.id);
                var item = new Singularity.Hub.Item (account.id, c.id, text ? Singularity.Hub.ItemKind.TEXT : Singularity.Hub.ItemKind.CHAT);
                item.sender = c.title;
                item.subject = c.kind == ConversationKind.DIRECT ? "" : c.last_author;
                item.preview = c.last_preview;
                item.timestamp = c.activity;
                item.unread = c.unread > 0 || c.mentioned;
                item.count = int.max (1, c.unread);
                item.priority = c.mentioned;
                item.app_id = "dev.sinty.messages";
                item.body = body_of (ch, c);
                Singularity.Hub.publish (item);
            }
            var before = published.has_key (ch.id) ? published[ch.id] : new Gee.HashSet<string> ();
            foreach (var id in before) {
                if (!keep.contains (id)) Singularity.Hub.withdraw (account.id, id);
            }
            published[ch.id] = keep;
        }

        private string body_of (Channel ch, Conversation c) {
            var list = app.engine.messages (ch.id, c.id);
            if (list.size == 0) return c.last_preview;
            var sb = new StringBuilder ();
            int start = int.max (0, list.size - BODY_MESSAGES);
            for (int i = start; i < list.size; i++) {
                var m = list[i];
                string line = m.preview ();
                if (line == "" || m.system) continue;
                if (sb.len > 0) sb.append ("\n\n");
                string who = m.outgoing ? _("You") : (m.author_name != "" ? m.author_name : c.title);
                sb.append ("%s\n%s".printf (who, line));
            }
            return sb.len > 0 ? sb.str : c.last_preview;
        }

        private void on_action (string account, string id, string action) {
            if (!account.has_prefix (PREFIX)) return;
            var ch = app.engine.channel (account.substring (PREFIX.length));
            if (ch == null) return;
            var c = app.engine.find_conversation (ch.id, id);
            switch (action) {
                case "mark-read":
                    app.engine.mark_read.begin (ch, id, true);
                    break;
                case "mark-unread":
                    app.engine.mark_unread (ch, id);
                    break;
                case "delete":
                    if (c != null) hidden[ch.id + "\n" + id] = c.activity;
                    break;
                case "restore":
                    hidden.unset (ch.id + "\n" + id);
                    queue_flush ();
                    break;
                case "open":
                case "reply":
                    app.show_conversation (ch.id, id);
                    break;
            }
        }
    }
}
