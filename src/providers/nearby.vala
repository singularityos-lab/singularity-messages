using Singularity.Messaging;

namespace Singularity.Apps.Messages {

    public class NearbyPeersProvider : Object, Provider {
        public string id { owned get { return "nearby"; } }
        public string name { owned get { return _("Nearby Computers"); } }
        public string icon_name { owned get { return "computer-symbolic"; } }

        private NearbyPeersChannel? channel = null;

        public static NearbyPeersChannel? instance = null;

        public async Gee.List<Channel> discover () throws Error {
            var list = new Gee.ArrayList<Channel> ();
            if (!Singularity.Collab.Client.installed ()) return list;
            if (channel == null) {
                channel = new NearbyPeersChannel ();
                instance = channel;
                Singularity.Collab.Client.get_default ().people_changed.connect (() => channel.conversations_changed ());
            }
            list.add (channel);
            return list;
        }
    }

    public class NearbyPeersChannel : Channel {
        private const int KEEP = 1000;

        private string path;
        private Gee.HashMap<string, Conversation> convs = new Gee.HashMap<string, Conversation> ();
        private Gee.HashMap<string, Gee.ArrayList<Message>> logs = new Gee.HashMap<string, Gee.ArrayList<Message>> ();
        private uint save_id = 0;

        public NearbyPeersChannel () {
            Object (id: "nearby:local", provider_id: "nearby");
            title = _("Nearby Computers");
            icon_name = "computer-symbolic";
            self_id = "me";
            features = Features.REPLIES | Features.NEW_CONVERSATION;
            realtime = Realtime.PUSH;
            poll_seconds = 300;
            path = Path.build_filename (Environment.get_user_data_dir (), "singularity", "messages", "nearby.json");
            load ();
        }

        private void load () {
            string text;
            try {
                if (!FileUtils.get_contents (path, out text)) return;
                var parser = new Json.Parser ();
                parser.load_from_data (text);
                var root = parser.get_root ().get_object ();
                foreach (var n in Rest.arr (root, "conversations").get_elements ()) {
                    var o = n.get_object ();
                    var c = Conversation.from_json (o);
                    convs[c.id] = c;
                    var log = new Gee.ArrayList<Message> ();
                    foreach (var mn in Rest.arr (o, "messages").get_elements ()) log.add (Message.from_json (mn.get_object ()));
                    logs[c.id] = log;
                }
            } catch (Error e) {
            }
        }

        private void queue_save () {
            if (save_id != 0) return;
            save_id = Timeout.add (400, () => {
                save_id = 0;
                save ();
                return Source.REMOVE;
            });
        }

        private void save () {
            var arr = new Json.Array ();
            foreach (var c in convs.values) {
                var o = c.to_json ();
                var ma = new Json.Array ();
                var log = logs[c.id];
                if (log != null) foreach (var m in log) ma.add_object_element (m.to_json ());
                o.set_array_member ("messages", ma);
                arr.add_object_element (o);
            }
            var root = new Json.Object ();
            root.set_array_member ("conversations", arr);
            Store.write_json (path, root);
        }

        private Conversation conversation_for (string person, string name) {
            var c = convs[person];
            if (c == null) {
                c = new Conversation ();
                c.id = person;
                c.peer = person;
                c.kind = ConversationKind.DIRECT;
                convs[person] = c;
                logs[person] = new Gee.ArrayList<Message> ();
            }
            if (name != "") c.title = name;
            if (c.title == "") c.title = name_of (person);
            return c;
        }

        private static string name_of (string person) {
            foreach (var p in Singularity.Collab.Client.get_default ().people) {
                if (p.id == person) return p.name;
            }
            return _("Nearby Computer");
        }

        private void append (Conversation c, Message m) {
            var log = logs[c.id];
            log.add (m);
            while (log.size > KEEP) log.remove_at (0);
            c.activity = m.time;
            c.last_preview = m.preview ();
            c.last_author = m.outgoing ? _("You") : m.author_name;
            queue_save ();
        }

        public void receive (string person, string name, string payload) {
            var o = Singularity.Collab.Shared.decode (payload);
            if (o == null) return;
            var c = conversation_for (person, name);
            var m = new Message ();
            m.id = Rest.str (o, "id", Uuid.string_random ());
            m.conversation = person;
            m.author_id = person;
            m.author_name = c.title;
            m.text = Rest.str (o, "text");
            m.time = get_real_time () / 1000000;
            m.reply_to = Rest.str (o, "reply");
            m.reply_preview = Rest.str (o, "reply_preview");
            foreach (var existing in logs[c.id]) if (existing.id == m.id) return;
            c.unread++;
            append (c, m);
            var batch = new Gee.ArrayList<Message> ();
            batch.add (m);
            incoming (person, batch);
            conversations_changed ();
        }

        public override async Gee.List<Conversation> conversations (Cancellable? cancel = null) throws Error {
            var list = new Gee.ArrayList<Conversation> ();
            foreach (var c in convs.values) list.add (c);
            return list;
        }

        public override async Gee.List<Message> messages (string conversation, string? after, int limit, Cancellable? cancel = null) throws Error {
            var list = new Gee.ArrayList<Message> ();
            var log = logs[conversation];
            if (log == null) return list;
            bool take = after == null || after == "";
            foreach (var m in log) {
                if (take) list.add (m);
                else if (m.id == after) take = true;
            }
            if (list.size > limit) return list.slice (list.size - limit, list.size);
            return list;
        }

        public override async Message send (string conversation, string text, string? reply_to, Cancellable? cancel = null) throws Error {
            var c = conversation_for (conversation, "");
            var m = new Message ();
            m.id = Uuid.string_random ();
            m.conversation = conversation;
            m.author_id = "me";
            m.text = text;
            m.outgoing = true;
            m.time = get_real_time () / 1000000;
            var o = new Json.Object ();
            o.set_string_member ("id", m.id);
            o.set_string_member ("text", text);
            if (reply_to != null && reply_to != "") {
                o.set_string_member ("reply", reply_to);
                foreach (var prev in logs[c.id]) {
                    if (prev.id == reply_to) {
                        m.reply_to = reply_to;
                        m.reply_preview = prev.preview ();
                        o.set_string_member ("reply_preview", m.reply_preview);
                    }
                }
            }
            yield Singularity.Collab.Client.get_default ().send (conversation, "Message", "", Singularity.Collab.Shared.encode (o), text);
            append (c, m);
            return m;
        }

        public override async void mark_read (string conversation, string message, Cancellable? cancel = null) throws Error {
            var c = convs[conversation];
            if (c != null && c.unread != 0) {
                c.unread = 0;
                queue_save ();
            }
        }

        public override async string start (string peer, Cancellable? cancel = null) throws Error {
            conversation_for (peer, name_of (peer));
            queue_save ();
            return peer;
        }

        public override async Gee.List<Peer> search_people (string query, Cancellable? cancel = null) throws Error {
            var list = new Gee.ArrayList<Peer> ();
            string q = query.down ();
            foreach (var p in Singularity.Collab.Client.get_default ().people) {
                if (q == "" || p.name.down ().contains (q)) list.add (new Peer (p.id, p.name, p.provider_name));
            }
            return list;
        }

        public override void close () {
            if (save_id != 0) {
                Source.remove (save_id);
                save_id = 0;
                save ();
            }
        }
    }
}
