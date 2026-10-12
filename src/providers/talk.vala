using Singularity.Accounts;
using Singularity.Messaging;

namespace Singularity.Apps.Messages {

    public class TalkProvider : Object, Provider {
        public string id { owned get { return "talk"; } }
        public string name { owned get { return "Nextcloud Talk"; } }
        public string icon_name { owned get { return "singularity-account-nextcloud-symbolic"; } }

        public async Gee.List<Channel> discover () throws Error {
            var list = new Gee.ArrayList<Channel> ();
            foreach (var a in Manager.get_default ().get_accounts_for (Capability.CHAT)) {
                if (a.provider == "nextcloud" && (a.get_endpoint ("chat-api") ?? "talk") == "talk") list.add (new TalkChannel (a));
            }
            return list;
        }
    }

    public class TalkChannel : Channel {
        private const string[] HIDDEN = { "reaction", "reaction_deleted", "reaction_revoked", "message_deleted", "message_edited", "poll_voted" };

        private Account account;
        private Rest rest;
        private string server;

        public TalkChannel (Account account) {
            Object (id: "talk:" + account.id, provider_id: "talk");
            this.account = account;
            account_id = account.id;
            title = account.display_name;
            icon_name = "singularity-account-nextcloud-symbolic";
            server = account.server;
            while (server.has_suffix ("/")) server = server.substring (0, server.length - 1);
            self_id = account.get_endpoint ("dav-user") ?? account.identity;
            features = Features.ATTACHMENTS | Features.REPLIES | Features.EDIT | Features.DELETE | Features.REACTIONS | Features.READ_MARKERS | Features.NEW_CONVERSATION;
            realtime = Realtime.LONG_POLL;
            poll_seconds = 30;
            rest = new Rest (account);
            rest.header ("OCS-APIRequest", "true");
        }

        private string api (string path) {
            return server + "/ocs/v2.php/apps/spreed/api/" + path;
        }

        private static Json.Node? data (RestReply r) {
            var ocs = Rest.obj (r.object (), "ocs");
            if (ocs == null || !ocs.has_member ("data")) return null;
            return ocs.get_member ("data");
        }

        private static string esc (string s) {
            return Uri.escape_string (s, null, false);
        }

        public override async Gee.List<Conversation> conversations (Cancellable? cancel = null) throws Error {
            var r = yield rest.ok ("GET", api ("v4/room"), null, null, cancel);
            var list = new Gee.ArrayList<Conversation> ();
            var d = data (r);
            if (d == null || d.get_node_type () != Json.NodeType.ARRAY) return list;
            foreach (var n in d.get_array ().get_elements ()) {
                var o = n.get_object ();
                var c = new Conversation ();
                c.id = Rest.str (o, "token");
                c.title = Rest.str (o, "displayName", Rest.str (o, "name"));
                int type = (int) Rest.num (o, "type");
                c.kind = type == 1 || type == 5 ? ConversationKind.DIRECT : ConversationKind.GROUP;
                if (type == 1) c.peer = Rest.str (o, "name");
                c.unread = (int) Rest.num (o, "unreadMessages");
                c.mentioned = Rest.num (o, "unreadMention") != 0;
                c.activity = Rest.num (o, "lastActivity");
                c.read_only = Rest.num (o, "readOnly") != 0;
                int level = (int) Rest.num (o, "notificationLevel");
                c.muted = level == 3;
                c.mentions_only = level == 2;
                c.avatar_url = api ("v1/room/%s/avatar".printf (esc (c.id)));
                var last = Rest.obj (o, "lastMessage");
                if (last != null) {
                    var m = parse (last, c.id);
                    c.last_preview = m.preview ();
                    c.last_author = m.system ? "" : (m.outgoing ? _("You") : m.author_name);
                }
                list.add (c);
            }
            return list;
        }

        private string substitute (string text, Json.Object? params, Message m) {
            if (params == null) return text;
            string s = text;
            foreach (string key in params.get_members ()) {
                var p = params.get_object_member (key);
                if (p == null) continue;
                string type = Rest.str (p, "type");
                if (type == "file") {
                    var a = new Attachment ();
                    a.name = Rest.str (p, "name");
                    a.mime = Rest.str (p, "mimetype");
                    a.size = Rest.num (p, "size");
                    string path = Rest.str (p, "path");
                    string url = path != "" ? "%s/remote.php/dav/files/%s/%s".printf (server, esc (self_id), path_escape (path)) : Rest.str (p, "link");
                    a.url = url;
                    m.attachments.add (a);
                    s = s.replace ("{" + key + "}", "");
                    continue;
                }
                string name = Rest.str (p, "name");
                if (type == "user" || type == "guest" || type == "call" || type == "user-group") name = "@" + name;
                s = s.replace ("{" + key + "}", name);
            }
            return s.strip ();
        }

        private static string path_escape (string path) {
            var sb = new StringBuilder ();
            foreach (string part in path.split ("/")) {
                if (sb.len > 0) sb.append_c ('/');
                sb.append (Uri.escape_string (part, null, false));
            }
            return sb.str;
        }

        private Message parse (Json.Object o, string conversation) {
            var m = new Message ();
            m.id = Rest.str (o, "id");
            m.conversation = conversation;
            m.author_id = Rest.str (o, "actorId");
            m.author_name = Rest.str (o, "actorDisplayName", m.author_id);
            m.time = Rest.num (o, "timestamp");
            m.system = Rest.str (o, "systemMessage") != "";
            m.outgoing = Rest.str (o, "actorType") == "users" && m.author_id == self_id;
            m.deleted = Rest.str (o, "messageType") == "comment_deleted";
            m.edited = Rest.num (o, "lastEditTimestamp") > 0;
            m.text = substitute (Rest.str (o, "message"), Rest.obj (o, "messageParameters"), m);
            var parent = Rest.obj (o, "parent");
            if (parent != null) {
                m.reply_to = Rest.str (parent, "id");
                var pm = new Message ();
                pm.text = substitute (Rest.str (parent, "message"), Rest.obj (parent, "messageParameters"), pm);
                m.reply_preview = "%s: %s".printf (Rest.str (parent, "actorDisplayName"), pm.preview ());
            }
            var reactions = Rest.obj (o, "reactions");
            if (reactions != null) {
                foreach (string k in reactions.get_members ()) m.reactions[k] = (int) reactions.get_int_member (k);
            }
            foreach (var n in Rest.arr (o, "reactionsSelf").get_elements ()) m.own_reactions.add (n.get_string ());
            return m;
        }

        private Gee.List<Message> parse_list (RestReply r, string conversation, bool reverse) {
            var list = new Gee.ArrayList<Message> ();
            var d = data (r);
            if (d == null || d.get_node_type () != Json.NodeType.ARRAY) return list;
            foreach (var n in d.get_array ().get_elements ()) {
                var o = n.get_object ();
                if (Rest.str (o, "systemMessage") in HIDDEN) continue;
                list.add (parse (o, conversation));
            }
            if (reverse) {
                var rev = new Gee.ArrayList<Message> ();
                for (int i = list.size - 1; i >= 0; i--) rev.add (list[i]);
                return rev;
            }
            return list;
        }

        public override async Gee.List<Message> messages (string conversation, string? after, int limit, Cancellable? cancel = null) throws Error {
            var q = new HashTable<string, string> (str_hash, str_equal);
            q["limit"] = limit.clamp (1, 200).to_string ();
            q["setReadMarker"] = "0";
            q["includeLastKnown"] = "0";
            if (after != null && after != "") {
                q["lookIntoFuture"] = "1";
                q["lastKnownMessageId"] = after;
                q["timeout"] = "0";
            } else {
                q["lookIntoFuture"] = "0";
            }
            var r = yield rest.call ("GET", Rest.query (api ("v1/chat/" + esc (conversation)), q), null, null, cancel);
            if (r.status == 304) return new Gee.ArrayList<Message> ();
            if (r.status != 200) throw Rest.error_for (r, "chat");
            return parse_list (r, conversation, after == null || after == "");
        }

        public override async bool wait (string conversation, string after, Cancellable cancel) throws Error {
            var q = new HashTable<string, string> (str_hash, str_equal);
            q["lookIntoFuture"] = "1";
            q["lastKnownMessageId"] = after;
            q["timeout"] = "30";
            q["limit"] = "1";
            q["setReadMarker"] = "0";
            var r = yield rest.call ("GET", Rest.query (api ("v1/chat/" + esc (conversation)), q), null, null, cancel);
            return r.status == 200;
        }

        private Message single (RestReply r, string conversation) throws Error {
            var d = data (r);
            if (d == null || d.get_node_type () != Json.NodeType.OBJECT) throw new MessagingError.PROTOCOL (_("The server sent no message back"));
            return parse (d.get_object (), conversation);
        }

        public override async Message send (string conversation, string text, string? reply_to, Cancellable? cancel = null) throws Error {
            var f = new HashTable<string, string> (str_hash, str_equal);
            f["message"] = text;
            if (reply_to != null && reply_to != "") f["replyTo"] = reply_to;
            var r = yield rest.ok ("POST", api ("v1/chat/" + esc (conversation)), "application/x-www-form-urlencoded", Rest.form (f), cancel);
            return single (r, conversation);
        }

        public override async void mark_read (string conversation, string message, Cancellable? cancel = null) throws Error {
            var f = new HashTable<string, string> (str_hash, str_equal);
            f["lastReadMessage"] = message;
            yield rest.ok ("POST", api ("v1/chat/%s/read".printf (esc (conversation))), "application/x-www-form-urlencoded", Rest.form (f), cancel);
        }

        public override async void edit (string conversation, string message, string text, Cancellable? cancel = null) throws Error {
            var f = new HashTable<string, string> (str_hash, str_equal);
            f["message"] = text;
            yield rest.ok ("PUT", api ("v1/chat/%s/%s".printf (esc (conversation), esc (message))), "application/x-www-form-urlencoded", Rest.form (f), cancel);
        }

        public override async void remove (string conversation, string message, Cancellable? cancel = null) throws Error {
            yield rest.ok ("DELETE", api ("v1/chat/%s/%s".printf (esc (conversation), esc (message))), null, null, cancel);
        }

        public override async void react (string conversation, string message, string emoji, bool add, Cancellable? cancel = null) throws Error {
            var f = new HashTable<string, string> (str_hash, str_equal);
            f["reaction"] = emoji;
            string url = api ("v1/reaction/%s/%s".printf (esc (conversation), esc (message)));
            if (add) yield rest.ok ("POST", url, "application/x-www-form-urlencoded", Rest.form (f), cancel);
            else yield rest.ok ("DELETE", Rest.query (url, f), null, null, cancel);
        }

        public override async string start (string peer, Cancellable? cancel = null) throws Error {
            var f = new HashTable<string, string> (str_hash, str_equal);
            f["roomType"] = "1";
            f["invite"] = peer;
            var r = yield rest.ok ("POST", api ("v4/room"), "application/x-www-form-urlencoded", Rest.form (f), cancel);
            var d = data (r);
            if (d == null || d.get_node_type () != Json.NodeType.OBJECT) throw new MessagingError.PROTOCOL (_("The server did not create the conversation"));
            return Rest.str (d.get_object (), "token");
        }

        public override async Gee.List<Peer> search_people (string query, Cancellable? cancel = null) throws Error {
            var q = new HashTable<string, string> (str_hash, str_equal);
            q["search"] = query;
            q["itemType"] = "call";
            q["itemId"] = "new";
            q["shareTypes[]"] = "0";
            q["limit"] = "20";
            var r = yield rest.ok ("GET", Rest.query (server + "/ocs/v2.php/core/autocomplete/get", q), null, null, cancel);
            var list = new Gee.ArrayList<Peer> ();
            var d = data (r);
            if (d == null || d.get_node_type () != Json.NodeType.ARRAY) return list;
            foreach (var n in d.get_array ().get_elements ()) {
                var o = n.get_object ();
                string pid = Rest.str (o, "id");
                if (pid == self_id) continue;
                list.add (new Peer (pid, Rest.str (o, "label", pid), Rest.str (o, "subline")));
            }
            return list;
        }

        public override async Message upload (string conversation, File file, string caption, Cancellable? cancel = null) throws Error {
            string name = file.get_basename ();
            string folder = "%s/remote.php/dav/files/%s/Talk".printf (server, esc (self_id));
            yield rest.call ("MKCOL", folder, null, null, cancel);
            string target = "%s_%s".printf (new DateTime.now_local ().format ("%Y%m%d-%H%M%S"), name);
            var info = yield file.query_info_async (FileAttribute.STANDARD_SIZE + "," + FileAttribute.STANDARD_CONTENT_TYPE, FileQueryInfoFlags.NONE, Priority.DEFAULT, cancel);
            var source = new UploadSource (file, 0, info.get_size ());
            string type = ContentType.get_mime_type (info.get_content_type () ?? "application/octet-stream") ?? "application/octet-stream";
            var put = yield rest.http.send_file ("PUT", folder + "/" + esc (target), type, source, null, true, null, cancel);
            if (!put.ok) throw new MessagingError.PROTOCOL (_("The file could not be uploaded (HTTP %u)").printf (put.status));
            var f = new HashTable<string, string> (str_hash, str_equal);
            f["shareType"] = "10";
            f["shareWith"] = conversation;
            f["path"] = "/Talk/" + target;
            if (caption.strip () != "") {
                var meta = new Json.Object ();
                meta.set_string_member ("caption", caption.strip ());
                var gen = new Json.Generator ();
                var node = new Json.Node (Json.NodeType.OBJECT);
                node.set_object (meta);
                gen.set_root (node);
                f["talkMetaData"] = gen.to_data (null);
            }
            yield rest.ok ("POST", server + "/ocs/v2.php/apps/files_sharing/api/v1/shares", "application/x-www-form-urlencoded", Rest.form (f), cancel);
            var m = new Message ();
            m.conversation = conversation;
            m.outgoing = true;
            m.author_id = self_id;
            m.time = get_real_time () / 1000000;
            m.text = caption;
            var a = new Attachment ();
            a.name = name;
            a.mime = type;
            a.size = info.get_size ();
            a.path = file.get_path () ?? "";
            m.attachments.add (a);
            return m;
        }

        public override async Bytes? download (Attachment attachment, Cancellable? cancel = null) throws Error {
            if (attachment.url == "") return null;
            var r = yield rest.http.send ("GET", attachment.url, null, null, null, cancel);
            if (!r.ok) return null;
            return r.body;
        }
    }
}
