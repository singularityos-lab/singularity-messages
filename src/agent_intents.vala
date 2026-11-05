using Singularity.Messaging;

namespace Singularity.Apps.Messages {

    internal class MessagesIntents : Object {
        private const string TARGET = "{\"type\":\"object\",\"properties\":{\"channel\":{\"type\":\"string\"},\"conversation\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\"}},\"required\":[\"channel\",\"conversation\"]}";

        private static string text (Json.Object args, string key) {
            return args.has_member (key) ? args.get_string_member (key) : "";
        }

        private static int64 limit (Json.Object args, int64 fallback) {
            int64 n = args.has_member ("limit") ? args.get_int_member ("limit") : fallback;
            return n.clamp (1, 500);
        }

        private static string kind_name (ConversationKind kind) {
            return kind.to_id ();
        }

        private static Json.Node conversation (Channel ch, Conversation c) {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("channel").add_string_value (ch.id);
            b.set_member_name ("account").add_string_value (ch.title);
            b.set_member_name ("conversation").add_string_value (c.id);
            b.set_member_name ("title").add_string_value (c.title);
            b.set_member_name ("kind").add_string_value (kind_name (c.kind));
            b.set_member_name ("peer").add_string_value (c.peer);
            b.set_member_name ("unread").add_int_value (c.unread);
            b.set_member_name ("last_author").add_string_value (c.last_author);
            b.set_member_name ("last_preview").add_string_value (c.last_preview);
            b.set_member_name ("read_only").add_boolean_value (c.read_only);
            b.end_object ();
            return b.get_root ();
        }

        private static Json.Node message (Message m) {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("id").add_string_value (m.id);
            b.set_member_name ("author").add_string_value (m.outgoing ? "me" : m.author_name);
            b.set_member_name ("time").add_int_value (m.time);
            b.set_member_name ("text").add_string_value (m.deleted ? "" : m.text);
            b.set_member_name ("outgoing").add_boolean_value (m.outgoing);
            if (m.reply_preview != "") b.set_member_name ("reply_to").add_string_value (m.reply_preview);
            if (m.attachments.size > 0) b.set_member_name ("attachments").add_int_value (m.attachments.size);
            b.end_object ();
            return b.get_root ();
        }

        private static Json.Node array (Json.Array list) {
            var node = new Json.Node (Json.NodeType.ARRAY);
            node.set_array (list);
            return node;
        }

        private static async Channel find_channel (MessagesApp app, string id) throws Error {
            var ch = app.engine.channel (id);
            if (ch == null) {
                yield app.engine.discover ();
                ch = app.engine.channel (id);
            }
            if (ch == null) throw new IOError.NOT_FOUND ("no account %s", id);
            return ch;
        }

        private static async Json.Node list_async (MessagesApp app, Json.Object args) throws Error {
            if (app.engine.get_channels ().size == 0) yield app.engine.discover ();
            var result = new Json.Array ();
            int64 max = limit (args, 50);
            foreach (var e in app.engine.entries (text (args, "channel"), text (args, "query"))) {
                if (result.get_length () == max) break;
                if (args.has_member ("unread_only") && args.get_boolean_member ("unread_only") && e.conversation.unread == 0) continue;
                result.add_element (conversation (e.channel, e.conversation));
            }
            var accounts = new Json.Array ();
            foreach (var ch in app.engine.get_channels ()) {
                var a = new Json.Object ();
                a.set_string_member ("channel", ch.id);
                a.set_string_member ("title", ch.title);
                accounts.add_object_element (a);
            }
            var o = new Json.Object ();
            o.set_array_member ("accounts", accounts);
            o.set_array_member ("conversations", result);
            o.set_int_member ("unread", app.engine.unread_total ());
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (o);
            return node;
        }

        private static async Json.Node read_async (MessagesApp app, Json.Object args) throws Error {
            var ch = yield find_channel (app, text (args, "channel"));
            string conv = text (args, "conversation");
            var c = app.engine.find_conversation (ch.id, conv);
            if (c == null) throw new IOError.NOT_FOUND ("no conversation %s", conv);
            yield app.engine.load (ch, conv);
            var all = app.engine.messages (ch.id, conv);
            int64 max = limit (args, 50);
            int start = (int) int64.max (0, all.size - max);
            var list = new Json.Array ();
            for (int i = start; i < all.size; i++) {
                if (all[i].system) continue;
                list.add_element (message (all[i]));
            }
            var node = conversation (ch, c);
            node.get_object ().set_array_member ("messages", list);
            return node;
        }

        private static async Json.Node send_async (MessagesApp app, Json.Object args) throws Error {
            var ch = yield find_channel (app, text (args, "channel"));
            string conv = text (args, "conversation");
            string body = text (args, "text").strip ();
            if (body == "") throw new IOError.INVALID_ARGUMENT ("the message is empty");
            if (app.engine.find_conversation (ch.id, conv) == null) {
                var started = yield app.engine.start (ch, conv);
                if (started == null) throw new IOError.NOT_FOUND ("cannot start a conversation with %s", conv);
                conv = started;
            }
            var c = app.engine.find_conversation (ch.id, conv);
            if (c != null && c.read_only) throw new IOError.PERMISSION_DENIED ("this conversation is read only");
            yield app.engine.send (ch, conv, body, null);
            Message? last = null;
            foreach (var m in app.engine.messages (ch.id, conv)) if (m.outgoing && m.text == body) last = m;
            var o = new Json.Object ();
            o.set_string_member ("channel", ch.id);
            o.set_string_member ("conversation", conv);
            o.set_boolean_member ("verified", last != null && last.state != MessageState.FAILED);
            if (last != null) o.set_string_member ("state", last.state.to_id ());
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (o);
            return node;
        }

        private static async void run (MessagesApp app, owned AppIntentReply reply, Json.Object args, int which) {
            app.hold ();
            try {
                Json.Node node;
                if (which == 0) node = yield list_async (app, args);
                else if (which == 1) node = yield read_async (app, args);
                else node = yield send_async (app, args);
                reply (node, null);
            } catch (Error e) {
                reply (null, e);
            }
            app.release ();
        }

        internal static void install (MessagesApp app) {
            var agent = app.agent;
            agent.add_async_intent ("messages_list", "List the accounts and the most recent conversations, optionally filtered by account, words or unread only.",
                "{\"type\":\"object\",\"properties\":{\"channel\":{\"type\":\"string\"},\"query\":{\"type\":\"string\"},\"unread_only\":{\"type\":\"boolean\"},\"limit\":{\"type\":\"integer\"}}}",
                Singularity.AppIntentRisk.READ, (args, reply) => run.begin (app, (owned) reply, args, 0));
            agent.add_async_intent ("messages_read", "Read the latest messages of a conversation.", TARGET,
                Singularity.AppIntentRisk.READ, (args, reply) => run.begin (app, (owned) reply, args, 1));
            agent.add_intent ("messages_prepare", "Open a conversation with a person and put a draft in the composer without sending it.",
                "{\"type\":\"object\",\"properties\":{\"person\":{\"type\":\"string\"},\"address\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    string person = text (args, "person"), address = text (args, "address");
                    if (person == "" && address == "") throw new IOError.INVALID_ARGUMENT ("give a person or an address");
                    app.compose (person, address, text (args, "text"));
                    var o = new Json.Object ();
                    o.set_string_member ("draft", text (args, "text"));
                    o.set_boolean_member ("sent", false);
                    var node = new Json.Node (Json.NodeType.OBJECT);
                    node.set_object (o);
                    return node;
                });
            agent.add_async_intent ("messages_send", "Send a text message to a conversation, or to a new peer on an account.",
                "{\"type\":\"object\",\"properties\":{\"channel\":{\"type\":\"string\"},\"conversation\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"}},\"required\":[\"channel\",\"conversation\",\"text\"]}",
                Singularity.AppIntentRisk.IRREVERSIBLE, (args, reply) => run.begin (app, (owned) reply, args, 2));
        }
    }
}
