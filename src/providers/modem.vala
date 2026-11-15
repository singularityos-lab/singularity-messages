using Singularity.Messaging;

namespace Singularity.Apps.Messages {

    public class ModemClient : Object {
        public const string NAME = "org.freedesktop.ModemManager1";
        public const string ROOT = "/org/freedesktop/ModemManager1";
        public const string MODEM = "org.freedesktop.ModemManager1.Modem";
        public const string MESSAGING = "org.freedesktop.ModemManager1.Modem.Messaging";
        public const string SMS = "org.freedesktop.ModemManager1.Sms";

        private static ModemClient? instance = null;
        public DBusConnection? bus = null;
        public Gee.ArrayList<string> modems = new Gee.ArrayList<string> ();
        public Gee.HashMap<string, string> labels = new Gee.HashMap<string, string> ();
        private bool started = false;

        public signal void changed ();
        public signal void sms_added (string modem, string path, bool received);
        public signal void sms_deleted (string modem, string path);

        public static ModemClient get_default () {
            if (instance == null) instance = new ModemClient ();
            return instance;
        }

        public async void start () {
            if (started) return;
            started = true;
            try {
                bus = yield Bus.get (BusType.SYSTEM);
            } catch (Error e) {
                return;
            }
            bus.signal_subscribe (NAME, "org.freedesktop.DBus.ObjectManager", null, ROOT, null, DBusSignalFlags.NONE,
                () => refresh.begin ());
            bus.signal_subscribe (NAME, MESSAGING, null, null, null, DBusSignalFlags.NONE, on_messaging);
            yield refresh ();
        }

        private void on_messaging (DBusConnection conn, string? sender, string path, string iface, string member, Variant args) {
            if (member == "Added") {
                sms_added (path, args.get_child_value (0).get_string (), args.get_child_value (1).get_boolean ());
            } else if (member == "Deleted") {
                sms_deleted (path, args.get_child_value (0).get_string ());
            }
        }

        public async void refresh () {
            if (bus == null) return;
            Variant reply;
            try {
                reply = yield bus.call (NAME, ROOT, "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", null,
                    new VariantType ("(a{oa{sa{sv}}})"), DBusCallFlags.NONE, -1);
            } catch (Error e) {
                if (modems.size > 0) {
                    modems.clear ();
                    changed ();
                }
                return;
            }
            var found = new Gee.ArrayList<string> ();
            var iter = reply.get_child_value (0).iterator ();
            string path;
            Variant ifaces;
            while (iter.next ("{o@a{sa{sv}}}", out path, out ifaces)) {
                if (ifaces.lookup_value (MESSAGING, null) == null) continue;
                found.add (path);
                labels[path] = label_of (ifaces.lookup_value (MODEM, null));
            }
            found.sort ();
            if (found.size == modems.size && found.contains_all (modems)) return;
            modems = found;
            changed ();
        }

        private static string label_of (Variant? props) {
            if (props != null) {
                var numbers = props.lookup_value ("OwnNumbers", new VariantType ("as"));
                if (numbers != null && numbers.n_children () > 0 && numbers.get_child_value (0).get_string () != "") {
                    return numbers.get_child_value (0).get_string ();
                }
                var model = props.lookup_value ("Model", VariantType.STRING);
                if (model != null && model.get_string ().strip () != "") return model.get_string ().strip ();
            }
            return _("SIM");
        }

        public async Variant call (string path, string iface, string method, Variant? args, string reply_type) throws Error {
            if (bus == null) throw new MessagingError.NOT_SUPPORTED (_("No modem"));
            return yield bus.call (NAME, path, iface, method, args, new VariantType (reply_type), DBusCallFlags.NONE, 60000);
        }

        public async Variant props_of (string path, string iface) throws Error {
            var reply = yield call (path, "org.freedesktop.DBus.Properties", "GetAll", new Variant ("(s)", iface), "(a{sv})");
            return reply.get_child_value (0);
        }
    }

    public class ModemSmsChannel : Channel {
        private const uint STATE_RECEIVED = 3;
        private const uint STATE_SENDING = 4;
        private const uint STATE_SENT = 5;
        private const uint PDU_SUBMIT = 2;

        private string modem;
        private Gee.HashMap<string, Message> cache = new Gee.HashMap<string, Message> ();
        private Gee.HashMap<string, int64?> first_seen = new Gee.HashMap<string, int64?> ();
        private KeyFile seen = new KeyFile ();
        private string seen_path;
        private bool loaded = false;

        public ModemSmsChannel (string modem, string label) {
            Object (id: "sms:modem:" + Path.get_basename (modem), provider_id: "sms");
            this.modem = modem;
            title = label;
            icon_name = "phone-symbolic";
            self_id = "me";
            features = Features.NEW_CONVERSATION;
            realtime = Realtime.PUSH;
            poll_seconds = 300;
            seen_path = Path.build_filename (Environment.get_user_data_dir (), "singularity-messages", "sms-read.ini");
            try {
                seen.load_from_file (seen_path, KeyFileFlags.NONE);
            } catch (Error e) {
            }
            var client = ModemClient.get_default ();
            client.sms_added.connect (on_added);
            client.sms_deleted.connect ((m, path) => {
                if (m != modem) return;
                cache.unset (path);
                conversations_changed ();
            });
        }

        public static string normalize (string number) {
            var sb = new StringBuilder ();
            unichar c;
            int i = 0;
            string n = number.strip ();
            while (n.get_next_char (ref i, out c)) {
                if (c.isdigit () || (c == '+' && sb.len == 0)) sb.append_unichar (c);
            }
            return sb.len > 0 ? sb.str : n;
        }

        private void on_added (string m, string path, bool received) {
            if (m != modem) return;
            load_one.begin (path, (obj, res) => {
                var msg = load_one.end (res);
                if (msg == null) return;
                if (received && !msg.outgoing) {
                    var batch = new Gee.ArrayList<Message> ();
                    batch.add (msg);
                    incoming (msg.conversation, batch);
                }
                conversations_changed ();
            });
        }

        private async Message? load_one (string path) {
            Variant props;
            try {
                props = yield ModemClient.get_default ().props_of (path, ModemClient.SMS);
            } catch (Error e) {
                return null;
            }
            var state = props.lookup_value ("State", VariantType.UINT32);
            var pdu = props.lookup_value ("PduType", VariantType.UINT32);
            var number = props.lookup_value ("Number", VariantType.STRING);
            var text = props.lookup_value ("Text", VariantType.STRING);
            var stamp = props.lookup_value ("Timestamp", VariantType.STRING);
            if (number == null || number.get_string () == "") return null;
            uint st = state != null ? state.get_uint32 () : 0;
            if (st != STATE_RECEIVED && st != STATE_SENT && st != STATE_SENDING) return null;
            var m = new Message ();
            m.id = path;
            m.conversation = normalize (number.get_string ());
            m.text = text != null ? text.get_string () : "";
            m.outgoing = pdu != null && pdu.get_uint32 () == PDU_SUBMIT;
            m.author_id = m.outgoing ? "me" : m.conversation;
            m.author_name = m.outgoing ? "" : number.get_string ();
            m.time = time_of (path, stamp != null ? stamp.get_string () : "");
            cache[path] = m;
            return m;
        }

        private int64 time_of (string path, string stamp) {
            if (stamp != "") {
                var dt = new DateTime.from_iso8601 (stamp, new TimeZone.local ());
                if (dt != null) return dt.to_unix ();
            }
            if (!first_seen.has_key (path)) first_seen[path] = get_real_time () / 1000000;
            return first_seen[path];
        }

        private async void load_all () throws Error {
            var reply = yield ModemClient.get_default ().call (modem, ModemClient.MESSAGING, "List", null, "(ao)");
            var keep = new Gee.HashSet<string> ();
            foreach (var v in reply.get_child_value (0)) {
                string path = v.get_string ();
                keep.add (path);
                if (!cache.has_key (path)) yield load_one (path);
            }
            foreach (var path in cache.keys.to_array ()) {
                if (!keep.contains (path)) cache.unset (path);
            }
            loaded = true;
        }

        private int64 read_until (string number) {
            try {
                return seen.get_int64 ("read", number);
            } catch (Error e) {
                return 0;
            }
        }

        public override async Gee.List<Conversation> conversations (Cancellable? cancel = null) throws Error {
            yield load_all ();
            var by = new Gee.HashMap<string, Conversation> ();
            foreach (var m in cache.values) {
                var c = by[m.conversation];
                if (c == null) {
                    c = new Conversation ();
                    c.id = m.conversation;
                    c.peer = m.conversation;
                    c.title = m.outgoing ? m.conversation : m.author_name;
                    c.kind = ConversationKind.DIRECT;
                    by[m.conversation] = c;
                }
                if (!m.outgoing && m.time > read_until (m.conversation)) c.unread++;
                if (m.time >= c.activity) {
                    c.activity = m.time;
                    c.last_preview = m.preview ();
                    c.last_author = m.outgoing ? _("You") : "";
                }
            }
            var list = new Gee.ArrayList<Conversation> ();
            list.add_all (by.values);
            return list;
        }

        public override async Gee.List<Message> messages (string conversation, string? after, int limit, Cancellable? cancel = null) throws Error {
            if (!loaded) yield load_all ();
            var list = new Gee.ArrayList<Message> ();
            foreach (var m in cache.values) {
                if (m.conversation == conversation) list.add (m);
            }
            list.sort ((a, b) => a.time < b.time ? -1 : (a.time > b.time ? 1 : 0));
            if (list.size > limit) return list.slice (list.size - limit, list.size);
            return list;
        }

        public override async Message send (string conversation, string text, string? reply_to, Cancellable? cancel = null) throws Error {
            var client = ModemClient.get_default ();
            var props = new VariantBuilder (new VariantType ("a{sv}"));
            props.add ("{sv}", "number", new Variant.string (conversation));
            props.add ("{sv}", "text", new Variant.string (text));
            var reply = yield client.call (modem, ModemClient.MESSAGING, "Create", new Variant ("(a{sv})", props), "(o)");
            string path = reply.get_child_value (0).get_string ();
            yield client.call (path, ModemClient.SMS, "Send", null, "()");
            var m = new Message ();
            m.id = path;
            m.conversation = conversation;
            m.text = text;
            m.time = get_real_time () / 1000000;
            m.outgoing = true;
            m.author_id = "me";
            first_seen[path] = m.time;
            cache[path] = m;
            return m;
        }

        public override async void mark_read (string conversation, string message, Cancellable? cancel = null) throws Error {
            seen.set_int64 ("read", conversation, get_real_time () / 1000000);
            DirUtils.create_with_parents (Path.get_dirname (seen_path), 0700);
            seen.save_to_file (seen_path);
        }

        public override async string start (string peer, Cancellable? cancel = null) throws Error {
            return normalize (peer);
        }
    }
}
