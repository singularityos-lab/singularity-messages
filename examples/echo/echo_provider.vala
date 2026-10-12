using Singularity.Messaging;

namespace Echo {

    public class EchoProvider : Object, Provider {
        private EchoChannel? channel = null;

        public string id { owned get { return "echo"; } }
        public string name { owned get { return "Echo"; } }
        public string icon_name { owned get { return "chat-message-new-symbolic"; } }

        public async Gee.List<Channel> discover () throws Error {
            if (channel == null) channel = new EchoChannel ();
            var list = new Gee.ArrayList<Channel> ();
            list.add (channel);
            return list;
        }
    }

    public class EchoChannel : Channel {
        private Gee.ArrayList<Message> log = new Gee.ArrayList<Message> ();
        private Conversation room;
        private int serial = 0;

        public EchoChannel () {
            Object (id: "echo:local", provider_id: "echo");
            title = "Echo";
            icon_name = "chat-message-new-symbolic";
            self_id = "me";
            features = Features.REPLIES;
            realtime = Realtime.PUSH;
            room = new Conversation ();
            room.id = "echo";
            room.title = "Echo Bot";
            room.kind = ConversationKind.DIRECT;
            post ("bot", "Echo Bot", "Hello! Write anything and I will answer.", null);
        }

        private Message post (string author, string name, string text, string? reply_to) {
            var m = new Message ();
            m.id = "%d".printf (++serial);
            m.conversation = room.id;
            m.author_id = author;
            m.author_name = name;
            m.text = text;
            m.outgoing = author == "me";
            m.time = get_real_time () / 1000000;
            if (reply_to != null) m.reply_to = reply_to;
            log.add (m);
            room.activity = m.time;
            room.last_preview = m.preview ();
            return m;
        }

        public override async Gee.List<Conversation> conversations (Cancellable? cancel = null) throws Error {
            var list = new Gee.ArrayList<Conversation> ();
            list.add (room);
            return list;
        }

        public override async Gee.List<Message> messages (string conversation, string? after, int limit, Cancellable? cancel = null) throws Error {
            var list = new Gee.ArrayList<Message> ();
            bool take = after == null || after == "";
            foreach (var m in log) {
                if (take) list.add (m);
                else if (m.id == after) take = true;
            }
            return list;
        }

        public override async Message send (string conversation, string text, string? reply_to, Cancellable? cancel = null) throws Error {
            var mine = post ("me", "", text, reply_to);
            string id = mine.id;
            Timeout.add (800, () => {
                var answer = post ("bot", "Echo Bot", "You said: %s".printf (text), id);
                answer.reply_preview = "You: %s".printf (text);
                room.unread++;
                var batch = new Gee.ArrayList<Message> ();
                batch.add (answer);
                incoming (room.id, batch);
                return Source.REMOVE;
            });
            return mine;
        }

        public override async void mark_read (string conversation, string message, Cancellable? cancel = null) throws Error {
            room.unread = 0;
        }
    }
}

[ModuleInit]
public void peas_register_types (TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type (typeof (Singularity.Messaging.Provider), typeof (Echo.EchoProvider));
}
