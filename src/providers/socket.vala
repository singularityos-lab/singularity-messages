using Singularity.Messaging;

namespace Singularity.Apps.Messages {

    public class SocketProvider : Object, Provider {
        public string id { owned get { return "socket"; } }
        public string name { owned get { return _("Local Integrations"); } }
        public string icon_name { owned get { return "network-wired-symbolic"; } }

        private SocketChannel? channel = null;

        public static SocketChannel? instance = null;

        public async Gee.List<Channel> discover () throws Error {
            var list = new Gee.ArrayList<Channel> ();
            if (channel == null) {
                channel = new SocketChannel ();
                instance = channel;
            }
            list.add (channel);
            return list;
        }
    }

    public class IntegrationClient : Object {
        public string bot { get; set; default = ""; }
        public SocketConnection connection;
        public DataInputStream input;
        public OutputStream output;
        public Cancellable cancel = new Cancellable ();

        public IntegrationClient (SocketConnection connection) {
            this.connection = connection;
            input = new DataInputStream (connection.input_stream);
            output = connection.output_stream;
        }

        public void write (Json.Object o) {
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (o);
            string line = Json.to_string (node, false) + "\n";
            try {
                output.write_all (line.data, null);
                output.flush ();
            } catch (Error e) {
                cancel.cancel ();
            }
        }
    }

    public class SocketChannel : Channel {
        private const int KEEP = 1000;
        private const int QUEUE = 200;

        public signal void group_message (string bot, string group, string text);

        private string path;
        private string socket_path;
        private Gee.HashMap<string, Conversation> convs = new Gee.HashMap<string, Conversation> ();
        private Gee.HashMap<string, Gee.ArrayList<Message>> logs = new Gee.HashMap<string, Gee.ArrayList<Message>> ();
        private Gee.HashMap<string, IntegrationClient> online = new Gee.HashMap<string, IntegrationClient> ();
        private Gee.HashMap<string, Gee.ArrayList<Json.Object>> queued = new Gee.HashMap<string, Gee.ArrayList<Json.Object>> ();
        private SocketService? service = null;
        private uint save_id = 0;

        public SocketChannel () {
            Object (id: "socket:local", provider_id: "socket");
            title = _("Local Integrations");
            icon_name = "network-wired-symbolic";
            self_id = "me";
            features = Features.REPLIES;
            realtime = Realtime.PUSH;
            poll_seconds = 300;
            path = Path.build_filename (Environment.get_user_data_dir (), "singularity", "messages", "socket.json");
            socket_path = default_socket_path ();
            load ();
            listen ();
        }

        public static string default_socket_path () {
            string? custom = Environment.get_variable ("SINGULARITY_MESSAGES_SOCKET");
            if (custom != null && custom != "") return custom;
            return Path.build_filename (Environment.get_user_runtime_dir (), "singularity", "messages.sock");
        }

        private void listen () {
            DirUtils.create_with_parents (Path.get_dirname (socket_path), 0700);
            FileUtils.unlink (socket_path);
            service = new SocketService ();
            try {
                service.add_address (new UnixSocketAddress (socket_path), SocketType.STREAM, SocketProtocol.DEFAULT, null, null);
                FileUtils.chmod (socket_path, 0600);
            } catch (Error e) {
                warning ("Messages socket %s: %s", socket_path, e.message);
                service = null;
                return;
            }
            service.incoming.connect ((connection) => {
                serve.begin (new IntegrationClient (connection));
                return true;
            });
            service.start ();
        }

        private async void serve (IntegrationClient client) {
            while (!client.cancel.is_cancelled ()) {
                string? line = null;
                try {
                    line = yield client.input.read_line_utf8_async (Priority.DEFAULT, client.cancel);
                } catch (Error e) {
                    break;
                }
                if (line == null) break;
                if (line.strip () == "") continue;
                handle (client, line);
            }
            if (client.bot != "" && online[client.bot] == client) online.unset (client.bot);
            try {
                client.connection.close ();
            } catch (Error e) {
            }
        }

        private void reply_error (IntegrationClient client, string text) {
            var o = new Json.Object ();
            o.set_string_member ("type", "error");
            o.set_string_member ("message", text);
            client.write (o);
        }

        private void handle (IntegrationClient client, string line) {
            Json.Object o;
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (line);
                var root = parser.get_root ();
                if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                    reply_error (client, "expected a JSON object");
                    return;
                }
                o = root.get_object ();
            } catch (Error e) {
                reply_error (client, "invalid JSON");
                return;
            }
            string type = Rest.str (o, "type");
            if (type == "hello") {
                hello (client, o);
                return;
            }
            if (client.bot == "") {
                reply_error (client, "send hello first");
                return;
            }
            switch (type) {
                case "message":
                    post (client, o);
                    break;
                case "ping":
                    var pong = new Json.Object ();
                    pong.set_string_member ("type", "pong");
                    client.write (pong);
                    break;
                default:
                    reply_error (client, "unknown type");
                    break;
            }
        }

        private static bool valid_id (string id) {
            return id.length > 0 && id.length <= 64 && Regex.match_simple ("^[A-Za-z0-9._-]+$", id);
        }

        private void hello (IntegrationClient client, Json.Object o) {
            string bot = Rest.str (o, "id");
            if (!valid_id (bot)) {
                reply_error (client, "id must be 1-64 letters, digits, dots, dashes or underscores");
                return;
            }
            string name = Rest.str (o, "name", bot).strip ();
            if (name == "") name = bot;
            var previous = online[bot];
            if (previous != null && previous != client) previous.cancel.cancel ();
            client.bot = bot;
            online[bot] = client;
            var c = conversation_for (bot, name);
            queue_save ();
            conversations_changed ();
            var welcome = new Json.Object ();
            welcome.set_string_member ("type", "welcome");
            welcome.set_string_member ("conversation", c.id);
            client.write (welcome);
            var pending = queued[bot];
            if (pending != null) {
                foreach (var item in pending) client.write (item);
                queued.unset (bot);
            }
        }

        private void post (IntegrationClient client, Json.Object o) {
            string text = Rest.str (o, "text");
            if (text.strip () == "") {
                reply_error (client, "text is empty");
                return;
            }
            string group = Rest.str (o, "group");
            if (group != "") {
                group_message (client.bot, group, text);
                return;
            }
            var c = conversation_for (client.bot, "");
            var m = new Message ();
            m.id = Rest.str (o, "id", Uuid.string_random ());
            m.conversation = c.id;
            m.author_id = client.bot;
            m.author_name = c.title;
            m.text = text;
            m.time = get_real_time () / 1000000;
            m.reply_to = Rest.str (o, "reply");
            foreach (var existing in logs[c.id]) if (existing.id == m.id) return;
            c.unread++;
            append (c, m);
            var batch = new Gee.ArrayList<Message> ();
            batch.add (m);
            incoming (c.id, batch);
            conversations_changed ();
        }

        private void deliver (string bot, Json.Object o) {
            var client = online[bot];
            if (client != null && !client.cancel.is_cancelled ()) {
                client.write (o);
                return;
            }
            var pending = queued[bot];
            if (pending == null) {
                pending = new Gee.ArrayList<Json.Object> ();
                queued[bot] = pending;
            }
            pending.add (o);
            while (pending.size > QUEUE) pending.remove_at (0);
        }

        public void deliver_group (string bot, string group, string title, string author, string text, string message_id) {
            var o = new Json.Object ();
            o.set_string_member ("type", "message");
            o.set_string_member ("id", message_id);
            o.set_string_member ("group", group);
            o.set_string_member ("group_title", title);
            o.set_string_member ("author", author);
            o.set_string_member ("text", text);
            o.set_int_member ("time", get_real_time () / 1000000);
            deliver (bot, o);
        }

        public bool is_online (string bot) {
            return online.has_key (bot);
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

        private Conversation conversation_for (string bot, string name) {
            var c = convs[bot];
            if (c == null) {
                c = new Conversation ();
                c.id = bot;
                c.peer = bot;
                c.kind = ConversationKind.DIRECT;
                convs[bot] = c;
                logs[bot] = new Gee.ArrayList<Message> ();
            }
            if (name != "") c.title = name;
            if (c.title == "") c.title = bot;
            return c;
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

        public string title_of (string bot) {
            var c = convs[bot];
            return c != null ? c.title : bot;
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
            var c = convs[conversation];
            if (c == null) throw new MessagingError.NOT_FOUND (_("This integration is not known"));
            var m = new Message ();
            m.id = Uuid.string_random ();
            m.conversation = conversation;
            m.author_id = "me";
            m.text = text;
            m.outgoing = true;
            m.time = get_real_time () / 1000000;
            var o = new Json.Object ();
            o.set_string_member ("type", "message");
            o.set_string_member ("id", m.id);
            o.set_string_member ("author", Environment.get_real_name ());
            o.set_string_member ("text", text);
            o.set_int_member ("time", m.time);
            if (reply_to != null && reply_to != "") {
                o.set_string_member ("reply", reply_to);
                m.reply_to = reply_to;
            }
            deliver (conversation, o);
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

        public override async Gee.List<Peer> search_people (string query, Cancellable? cancel = null) throws Error {
            var list = new Gee.ArrayList<Peer> ();
            string q = query.down ();
            foreach (var c in convs.values) {
                if (q == "" || c.title.down ().contains (q)) list.add (new Peer (c.id, c.title, is_online (c.id) ? _("Connected") : _("Offline")));
            }
            return list;
        }

        public override void close () {
            if (service != null) {
                service.stop ();
                service = null;
                FileUtils.unlink (socket_path);
            }
            foreach (var client in online.values) client.cancel.cancel ();
            if (save_id != 0) {
                Source.remove (save_id);
                save_id = 0;
                save ();
            }
        }
    }
}
