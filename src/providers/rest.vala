using Singularity.Accounts;
using Singularity.Messaging;

namespace Singularity.Apps.Messages {

    public class RestReply : Object {
        public uint status;
        public Json.Node? root;
        public HttpResponse response;

        public Json.Object object () {
            if (root != null && root.get_node_type () == Json.NodeType.OBJECT) return root.get_object ();
            return new Json.Object ();
        }

        public Json.Array array_member (string name) {
            var o = object ();
            if (o.has_member (name) && o.get_member (name).get_node_type () == Json.NodeType.ARRAY) return o.get_array_member (name);
            return new Json.Array ();
        }
    }

    public class Rest : Object {
        public HttpClient http;
        private HashTable<string, string> base_headers = new HashTable<string, string> (str_hash, str_equal);

        public Rest (Account account) {
            http = new HttpClient (account, Capability.CHAT);
            base_headers["Accept"] = "application/json";
        }

        public void header (string name, string value) {
            base_headers[name] = value;
        }

        public static string form (HashTable<string, string> fields) {
            var sb = new StringBuilder ();
            fields.foreach ((k, v) => {
                if (sb.len > 0) sb.append_c ('&');
                sb.append (Uri.escape_string (k, null, false)).append_c ('=').append (Uri.escape_string (v, null, false));
            });
            return sb.str;
        }

        public static string query (string url, HashTable<string, string> fields) {
            return url + (url.contains ("?") ? "&" : "?") + form (fields);
        }

        public async RestReply call (string method, string url, string? content_type = null, string? body = null, Cancellable? cancel = null) throws Error {
            var headers = new HashTable<string, string> (str_hash, str_equal);
            base_headers.foreach ((k, v) => headers[k] = v);
            var response = yield http.send (method, url, content_type, body != null ? new Bytes (body.data) : null, headers, cancel);
            var reply = new RestReply ();
            reply.status = response.status;
            reply.response = response;
            if (response.body.get_size () > 0) {
                var parser = new Json.Parser ();
                try {
                    parser.load_from_data (response.text ());
                    reply.root = parser.get_root ();
                } catch (Error e) {
                }
            }
            return reply;
        }

        public async RestReply ok (string method, string url, string? content_type = null, string? body = null, Cancellable? cancel = null) throws Error {
            var reply = yield call (method, url, content_type, body, cancel);
            if (reply.status >= 200 && reply.status < 300) return reply;
            throw error_for (reply, method);
        }

        public async RestReply json (string method, string url, Json.Object body, Cancellable? cancel = null) throws Error {
            var gen = new Json.Generator ();
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (body);
            gen.set_root (node);
            return yield ok (method, url, "application/json", gen.to_data (null), cancel);
        }

        public static Error error_for (RestReply reply, string what) {
            switch (reply.status) {
                case 401:
                case 403:
                    return new MessagingError.AUTH (_("The service refused the request. Check the account in Settings."));
                case 404:
                case 410:
                    return new MessagingError.NOT_FOUND (_("The conversation or message no longer exists"));
                default:
                    return new MessagingError.PROTOCOL (_("The service answered HTTP %u").printf (reply.status));
            }
        }

        public static string str (Json.Object o, string name, string fallback = "") {
            if (!o.has_member (name)) return fallback;
            var n = o.get_member (name);
            if (n.get_node_type () != Json.NodeType.VALUE) return fallback;
            if (n.get_value_type () == typeof (string)) return n.get_string ();
            if (n.get_value_type () == typeof (int64)) return n.get_int ().to_string ();
            if (n.get_value_type () == typeof (bool)) return n.get_boolean () ? "true" : "false";
            return fallback;
        }

        public static int64 num (Json.Object o, string name, int64 fallback = 0) {
            if (!o.has_member (name)) return fallback;
            var n = o.get_member (name);
            if (n.get_node_type () != Json.NodeType.VALUE) return fallback;
            if (n.get_value_type () == typeof (int64)) return n.get_int ();
            if (n.get_value_type () == typeof (double)) return (int64) n.get_double ();
            if (n.get_value_type () == typeof (bool)) return n.get_boolean () ? 1 : 0;
            if (n.get_value_type () == typeof (string)) return int64.parse (n.get_string ());
            return fallback;
        }

        public static Json.Object? obj (Json.Object o, string name) {
            if (!o.has_member (name) || o.get_member (name).get_node_type () != Json.NodeType.OBJECT) return null;
            return o.get_object_member (name);
        }

        public static Json.Array arr (Json.Object o, string name) {
            if (!o.has_member (name) || o.get_member (name).get_node_type () != Json.NodeType.ARRAY) return new Json.Array ();
            return o.get_array_member (name);
        }

        public static int64 iso_time (string iso) {
            if (iso == "") return 0;
            var d = new DateTime.from_iso8601 (iso, new TimeZone.utc ());
            return d != null ? d.to_unix () : 0;
        }

        public static string strip_html (string html) {
            if (!html.contains ("<")) return decode_entities (html);
            string s = html;
            try {
                s = new Regex ("<br\\s*/?>|</p>|</div>", RegexCompileFlags.CASELESS).replace (s, -1, 0, "\n");
                s = new Regex ("<[^>]+>").replace (s, -1, 0, "");
            } catch (RegexError e) {
            }
            return decode_entities (s).strip ();
        }

        public static string decode_entities (string s) {
            return s.replace ("&nbsp;", " ").replace ("&lt;", "<").replace ("&gt;", ">").replace ("&quot;", "\"").replace ("&#39;", "'").replace ("&amp;", "&");
        }
    }
}
