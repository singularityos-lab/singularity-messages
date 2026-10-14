using Singularity.Messaging;

namespace Singularity.Apps.Messages {

    public class GroupMember : Object {
        public string channel { get; set; default = ""; }
        public string conversation { get; set; default = ""; }
        public string name { get; set; default = ""; }

        public GroupMember (string channel, string conversation, string name) {
            Object (channel: channel, conversation: conversation, name: name);
        }

        public bool same (string channel, string conversation) {
            return this.channel == channel && this.conversation == conversation;
        }

        public Json.Object to_json () {
            var o = new Json.Object ();
            o.set_string_member ("channel", channel);
            o.set_string_member ("conversation", conversation);
            o.set_string_member ("name", name);
            return o;
        }

        public static GroupMember from_json (Json.Object o) {
            return new GroupMember (Rest.str (o, "channel"), Rest.str (o, "conversation"), Rest.str (o, "name"));
        }
    }

    public class Group : Object {
        public string id { get; set; default = ""; }
        public string title { get; set; default = ""; }
        public bool hosted { get; set; default = true; }
        public Gee.ArrayList<GroupMember> members = new Gee.ArrayList<GroupMember> ();

        public GroupMember? member (string channel, string conversation) {
            foreach (var m in members) if (m.same (channel, conversation)) return m;
            return null;
        }
    }

    public class GroupsProvider : Object, Provider {
        public string id { owned get { return "groups"; } }
        public string name { owned get { return _("Groups"); } }
        public string icon_name { owned get { return "system-users-symbolic"; } }

        private unowned Engine engine;
        private GroupsChannel? channel = null;

        public static GroupsChannel? instance = null;

        public GroupsProvider (Engine engine) {
            this.engine = engine;
        }

        public async Gee.List<Channel> discover () throws Error {
            if (channel == null) {
                channel = new GroupsChannel (engine);
                instance = channel;
            }
            var list = new Gee.ArrayList<Channel> ();
            list.add (channel);
            return list;
        }
    }

    public class GroupsChannel : Channel {
        public const string NEARBY = "nearby:local";
        public const string SOCKET = "socket:local";
        private const int KEEP = 1000;

        private unowned Engine engine;
        private string path;
        private Gee.HashMap<string, Group> groups = new Gee.HashMap<string, Group> ();
        private Gee.HashMap<string, Conversation> convs = new Gee.HashMap<string, Conversation> ();
        private Gee.HashMap<string, Gee.ArrayList<Message>> logs = new Gee.HashMap<string, Gee.ArrayList<Message>> ();
        private Gee.HashSet<string> seen = new Gee.HashSet<string> ();
        private uint save_id = 0;
        private ulong nearby_handler = 0;
        private ulong socket_handler = 0;

        public GroupsChannel (Engine engine) {
            Object (id: "groups:local", provider_id: "groups");
            this.engine = engine;
            title = _("Groups");
            icon_name = "system-users-symbolic";
            self_id = "me";
            features = Features.NONE;
            realtime = Realtime.PUSH;
            poll_seconds = 300;
            path = Path.build_filename (Environment.get_user_data_dir (), "singularity", "messages", "groups.json");
            load ();
            engine.received.connect (on_received);
            hook_sources ();
            engine.channels_changed.connect (hook_sources);
        }

        private void hook_sources () {
            var nearby = NearbyPeersProvider.instance;
            if (nearby != null && nearby_handler == 0) {
                nearby_handler = nearby.group_message.connect ((person, group, gtitle, author, text, message_id) => {
                    from_nearby (person, group, gtitle, author, text, message_id);
                });
            }
            var socket = SocketProvider.instance;
            if (socket != null && socket_handler == 0) {
                socket_handler = socket.group_message.connect ((bot, group, text) => {
                    from_member (group, SOCKET, bot, socket.title_of (bot), text, Uuid.string_random ());
                });
            }
        }

        private static string self_name () {
            string name = Environment.get_real_name ();
            if (name == "" || name == "Unknown") name = Environment.get_user_name ();
            return name;
        }

        public Group create (string group_title, Gee.List<GroupMember> members) {
            var g = new Group ();
            g.id = Uuid.string_random ();
            g.title = group_title.strip () != "" ? group_title.strip () : _("New Group");
            g.hosted = true;
            foreach (var m in members) g.members.add (m);
            add_group (g);
            post_system (g, _("%s created the group").printf (self_name ()));
            queue_save ();
            conversations_changed ();
            return g;
        }

        private void add_group (Group g) {
            groups[g.id] = g;
            var c = convs[g.id];
            if (c == null) {
                c = new Conversation ();
                c.id = g.id;
                c.kind = ConversationKind.GROUP;
                convs[g.id] = c;
                logs[g.id] = new Gee.ArrayList<Message> ();
            }
            c.title = g.title;
        }

        private void post_system (Group g, string text) {
            var m = new Message ();
            m.id = Uuid.string_random ();
            m.conversation = g.id;
            m.text = text;
            m.system = true;
            m.time = get_real_time () / 1000000;
            append (convs[g.id], m);
        }

        private void from_nearby (string person, string group, string group_title, string author, string text, string message_id) {
            var g = groups[group];
            if (g == null) {
                g = new Group ();
                g.id = group;
                g.title = group_title != "" ? group_title : _("Group");
                g.hosted = false;
                g.members.add (new GroupMember (NEARBY, person, NearbyPeersProvider.instance != null ? NearbyPeersProvider.instance.title_of (person) : author));
                add_group (g);
                queue_save ();
                conversations_changed ();
            }
            if (g.member (NEARBY, person) == null) return;
            string shown = g.hosted && NearbyPeersProvider.instance != null ? NearbyPeersProvider.instance.title_of (person) : author;
            if (!g.hosted && group_title != "" && group_title != g.title) {
                g.title = group_title;
                convs[g.id].title = group_title;
            }
            from_member (group, NEARBY, person, shown, text, message_id);
        }

        private void from_member (string group, string channel_id, string conversation, string author, string text, string message_id) {
            var g = groups[group];
            if (g == null || g.member (channel_id, conversation) == null) return;
            if (!seen.add (message_id)) return;
            var c = convs[g.id];
            var m = new Message ();
            m.id = message_id;
            m.conversation = g.id;
            m.author_id = "%s/%s".printf (channel_id, conversation);
            m.author_name = author;
            m.text = text;
            m.time = get_real_time () / 1000000;
            c.unread++;
            append (c, m);
            var batch = new Gee.ArrayList<Message> ();
            batch.add (m);
            incoming (g.id, batch);
            conversations_changed ();
            if (g.hosted) fan_out (g, author, text, message_id, channel_id, conversation);
        }

        private void on_received (Channel ch, string conversation, Message m) {
            if (ch.id == NEARBY || ch.id == SOCKET || ch.id == id) return;
            if (m.outgoing || m.system) return;
            foreach (var g in groups.values) {
                if (!g.hosted || g.member (ch.id, conversation) == null) continue;
                string author = m.author_name != "" ? m.author_name : g.member (ch.id, conversation).name;
                from_member (g.id, ch.id, conversation, author, m.text, "%s/%s/%s".printf (ch.id, conversation, m.id));
            }
        }

        private void fan_out (Group g, string author, string text, string message_id, string skip_channel, string skip_conversation) {
            foreach (var member in g.members) {
                if (member.same (skip_channel, skip_conversation)) continue;
                deliver.begin (g, member, author, text, message_id);
            }
        }

        private async void deliver (Group g, GroupMember member, string author, string text, string message_id) {
            try {
                if (member.channel == NEARBY) {
                    var nearby = NearbyPeersProvider.instance;
                    if (nearby != null) yield nearby.send_group (member.conversation, g.id, g.title, author, text, message_id);
                    return;
                }
                if (member.channel == SOCKET) {
                    var socket = SocketProvider.instance;
                    if (socket != null) socket.deliver_group (member.conversation, g.id, g.title, author, text, message_id);
                    return;
                }
                var ch = engine.channel (member.channel);
                if (ch == null) return;
                string body = author == self_name () ? text : "%s: %s".printf (author, text);
                yield engine.send (ch, member.conversation, body, null);
            } catch (Error e) {
                problem (g, _("Not delivered to %s: %s").printf (member.name, e.message));
            }
        }

        private void problem (Group g, string text) {
            warning ("Groups: %s", text);
        }

        private void load () {
            string text;
            try {
                if (!FileUtils.get_contents (path, out text)) return;
                var parser = new Json.Parser ();
                parser.load_from_data (text);
                var root = parser.get_root ().get_object ();
                foreach (var n in Rest.arr (root, "groups").get_elements ()) {
                    var o = n.get_object ();
                    var g = new Group ();
                    g.id = Rest.str (o, "id");
                    if (g.id == "") continue;
                    g.title = Rest.str (o, "title");
                    g.hosted = o.has_member ("hosted") ? o.get_boolean_member ("hosted") : true;
                    foreach (var mn in Rest.arr (o, "members").get_elements ()) g.members.add (GroupMember.from_json (mn.get_object ()));
                    add_group (g);
                    var c = convs[g.id];
                    var conv = Rest.obj (o, "conversation");
                    if (conv != null) {
                        c.unread = (int) Rest.num (conv, "unread");
                        c.activity = Rest.num (conv, "activity");
                        c.last_preview = Rest.str (conv, "last_preview");
                        c.last_author = Rest.str (conv, "last_author");
                    }
                    foreach (var mn in Rest.arr (o, "messages").get_elements ()) {
                        var m = Message.from_json (mn.get_object ());
                        logs[g.id].add (m);
                        seen.add (m.id);
                    }
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
            foreach (var g in groups.values) {
                var o = new Json.Object ();
                o.set_string_member ("id", g.id);
                o.set_string_member ("title", g.title);
                o.set_boolean_member ("hosted", g.hosted);
                var members = new Json.Array ();
                foreach (var m in g.members) members.add_object_element (m.to_json ());
                o.set_array_member ("members", members);
                var c = convs[g.id];
                var conv = new Json.Object ();
                conv.set_int_member ("unread", c.unread);
                conv.set_int_member ("activity", c.activity);
                conv.set_string_member ("last_preview", c.last_preview);
                conv.set_string_member ("last_author", c.last_author);
                o.set_object_member ("conversation", conv);
                var ma = new Json.Array ();
                foreach (var m in logs[g.id]) ma.add_object_element (m.to_json ());
                o.set_array_member ("messages", ma);
                arr.add_object_element (o);
            }
            var root = new Json.Object ();
            root.set_array_member ("groups", arr);
            Store.write_json (path, root);
        }

        private void append (Conversation c, Message m) {
            var log = logs[c.id];
            log.add (m);
            while (log.size > KEEP) log.remove_at (0);
            c.activity = m.time;
            c.last_preview = m.preview ();
            c.last_author = m.system ? "" : (m.outgoing ? _("You") : m.author_name);
            queue_save ();
        }

        public Gee.List<Group> all_groups () {
            var list = new Gee.ArrayList<Group> ();
            foreach (var g in groups.values) list.add (g);
            return list;
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
            var g = groups[conversation];
            if (g == null) throw new MessagingError.NOT_FOUND (_("This group is not known"));
            var m = new Message ();
            m.id = Uuid.string_random ();
            m.conversation = conversation;
            m.author_id = "me";
            m.text = text;
            m.outgoing = true;
            m.time = get_real_time () / 1000000;
            seen.add (m.id);
            append (convs[conversation], m);
            fan_out (g, self_name (), text, m.id, "", "");
            return m;
        }

        public override async void mark_read (string conversation, string message, Cancellable? cancel = null) throws Error {
            var c = convs[conversation];
            if (c != null && c.unread != 0) {
                c.unread = 0;
                queue_save ();
            }
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
