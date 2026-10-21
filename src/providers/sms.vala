using Singularity.Messaging;

namespace Singularity.Apps.Messages {

    public class SmsProvider : Object, Provider {
        public string id { owned get { return "sms"; } }
        public string name { owned get { return _("Phone (SMS)"); } }
        public string icon_name { owned get { return "phone-symbolic"; } }

        private Gee.HashMap<string, SmsChannel> known = new Gee.HashMap<string, SmsChannel> ();
        private bool wired = false;
        private bool listed = false;

        public async Gee.List<Channel> discover () throws Error {
            var client = NearbyClient.get_default ();
            if (!wired) {
                wired = true;
                client.changed.connect (() => channels_changed ());
                client.conversations_changed.connect ((device) => {
                    var ch = known[device];
                    if (ch != null) ch.on_changed ();
                });
            }
            if (client.devices.size == 0 && !listed) {
                listed = true;
                yield client.refresh ();
            }
            var list = new Gee.ArrayList<Channel> ();
            foreach (var d in client.devices) {
                if (!d.paired || !d.has_plugin ("sms") || (d.device_type != "phone" && d.device_type != "tablet")) continue;
                var ch = known[d.id];
                if (ch == null) {
                    ch = new SmsChannel (d);
                    known[d.id] = ch;
                }
                ch.title = d.name;
                string why = d.reachable ? "" : _("%s is not reachable").printf (d.name);
                ch.attention = why;
                list.add (ch);
            }
            return list;
        }
    }

    public class SmsChannel : Channel {
        private string device;
        private Gee.HashMap<string, string> addresses = new Gee.HashMap<string, string> ();
        private bool requested = false;

        public SmsChannel (NearbyDevice d) {
            Object (id: "sms:" + d.id, provider_id: "sms");
            device = d.id;
            title = d.name;
            icon_name = "phone-symbolic";
            self_id = "me";
            features = Features.NEW_CONVERSATION;
            realtime = Realtime.PUSH;
            poll_seconds = 120;
        }

        private static int64 seconds (int64 stamp) {
            return stamp > 100000000000 ? stamp / 1000 : stamp;
        }

        private static string first_address (string raw) {
            foreach (string part in raw.split (",")) {
                if (part.strip () != "") return part.strip ();
            }
            return raw.strip ();
        }

        public void on_changed () {
            conversations_changed ();
        }

        public override async Gee.List<Conversation> conversations (Cancellable? cancel = null) throws Error {
            var client = NearbyClient.get_default ();
            if (!requested) {
                requested = true;
                yield client.simple ("RequestConversations", new Variant ("(s)", device));
            }
            var list = new Gee.ArrayList<Conversation> ();
            foreach (var v in yield client.list ("GetConversations", new Variant ("(s)", device))) {
                var c = new Conversation ();
                c.id = NearbyClient.int_of (v, "thread").to_string ();
                string address = NearbyClient.text_of (v, "address");
                addresses[c.id] = first_address (address);
                c.peer = addresses[c.id];
                c.title = address;
                c.kind = address.contains (",") ? ConversationKind.GROUP : ConversationKind.DIRECT;
                c.activity = seconds (NearbyClient.int_of (v, "date"));
                c.last_preview = NearbyClient.text_of (v, "body").replace ("\n", " ");
                c.unread = NearbyClient.flag_of (v, "read") ? 0 : 1;
                if (NearbyClient.flag_of (v, "outgoing")) c.last_author = _("You");
                list.add (c);
            }
            return list;
        }

        public override async Gee.List<Message> messages (string conversation, string? after, int limit, Cancellable? cancel = null) throws Error {
            var client = NearbyClient.get_default ();
            int64 thread = int64.parse (conversation);
            var items = yield client.list ("GetMessages", new Variant ("(sx)", device, thread));
            if (items.length == 0) {
                yield client.simple ("RequestConversation", new Variant ("(sx)", device, thread));
            }
            var list = new Gee.ArrayList<Message> ();
            foreach (var v in items) {
                var m = new Message ();
                m.id = NearbyClient.int_of (v, "id").to_string ();
                m.conversation = conversation;
                m.text = NearbyClient.text_of (v, "body");
                m.time = seconds (NearbyClient.int_of (v, "date"));
                m.outgoing = NearbyClient.flag_of (v, "outgoing");
                m.author_id = m.outgoing ? "me" : NearbyClient.text_of (v, "address");
                m.author_name = m.outgoing ? "" : m.author_id;
                list.add (m);
            }
            if (list.size > limit) return list.slice (list.size - limit, list.size);
            return list;
        }

        public override async Message send (string conversation, string text, string? reply_to, Cancellable? cancel = null) throws Error {
            string to = addresses[conversation] ?? conversation;
            yield NearbyClient.get_default ().call ("SendSms", new Variant ("(sss)", device, to, text));
            var m = new Message ();
            m.id = "local-%s".printf (Uuid.string_random ());
            m.conversation = conversation;
            m.text = text;
            m.time = get_real_time () / 1000000;
            m.outgoing = true;
            m.author_id = "me";
            return m;
        }

        public override async string start (string peer, Cancellable? cancel = null) throws Error {
            addresses[peer] = peer;
            return peer;
        }
    }
}
