using Singularity.Messaging;

namespace Singularity.Apps.Messages {

    public class Store : Object {
        public const int KEEP = 500;

        public string root { get; construct; }

        public Store () {
            string? dir = Environment.get_variable ("SINGULARITY_MESSAGES_DIR");
            Object (root: dir ?? Path.build_filename (Environment.get_user_data_dir (), "singularity", "messages"));
        }

        public static string safe (string id) {
            return Checksum.compute_for_string (ChecksumType.SHA1, id).substring (0, 20);
        }

        private string channel_dir (string channel) {
            return Path.build_filename (root, safe (channel));
        }

        public static void write_json (string path, Json.Object o) {
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (o);
            var gen = new Json.Generator ();
            gen.set_root (node);
            try {
                DirUtils.create_with_parents (Path.get_dirname (path), 0700);
                FileUtils.set_contents (path, gen.to_data (null));
                FileUtils.chmod (path, 0600);
            } catch (Error e) {
                warning ("messages: %s", e.message);
            }
        }

        private static Json.Object? read_json (string path) {
            string text;
            try {
                if (!FileUtils.get_contents (path, out text)) return null;
                var parser = new Json.Parser ();
                parser.load_from_data (text);
                var root = parser.get_root ();
                return root != null && root.get_node_type () == Json.NodeType.OBJECT ? root.get_object () : null;
            } catch (Error e) {
                return null;
            }
        }

        public Gee.List<Conversation> load_conversations (string channel) {
            var list = new Gee.ArrayList<Conversation> ();
            var o = read_json (Path.build_filename (channel_dir (channel), "conversations.json"));
            if (o == null) return list;
            foreach (var n in Rest.arr (o, "conversations").get_elements ()) list.add (Conversation.from_json (n.get_object ()));
            return list;
        }

        public void save_conversations (string channel, Gee.Collection<Conversation> list) {
            var arr = new Json.Array ();
            foreach (var c in list) arr.add_object_element (c.to_json ());
            var o = new Json.Object ();
            o.set_string_member ("channel", channel);
            o.set_array_member ("conversations", arr);
            write_json (Path.build_filename (channel_dir (channel), "conversations.json"), o);
        }

        public Gee.ArrayList<Message> load_messages (string channel, string conversation) {
            var list = new Gee.ArrayList<Message> ();
            var o = read_json (Path.build_filename (channel_dir (channel), safe (conversation) + ".json"));
            if (o == null) return list;
            foreach (var n in Rest.arr (o, "messages").get_elements ()) list.add (Message.from_json (n.get_object ()));
            return list;
        }

        public void save_messages (string channel, string conversation, Gee.List<Message> list) {
            var arr = new Json.Array ();
            int start = int.max (0, list.size - KEEP);
            for (int i = start; i < list.size; i++) arr.add_object_element (list[i].to_json ());
            var o = new Json.Object ();
            o.set_string_member ("conversation", conversation);
            o.set_array_member ("messages", arr);
            write_json (Path.build_filename (channel_dir (channel), safe (conversation) + ".json"), o);
        }

        public string cache_dir () {
            return Path.build_filename (Environment.get_user_cache_dir (), "singularity", "messages");
        }

        public void forget_channel (string channel) {
            string dir = channel_dir (channel);
            try {
                var d = Dir.open (dir);
                string? name;
                while ((name = d.read_name ()) != null) FileUtils.remove (Path.build_filename (dir, name));
                DirUtils.remove (dir);
            } catch (FileError e) {
            }
        }
    }
}
