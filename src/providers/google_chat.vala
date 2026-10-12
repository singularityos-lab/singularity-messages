using Singularity.Accounts;
using Singularity.Messaging;

namespace Singularity.Apps.Messages {

    public class GoogleChatProvider : Object, Provider {
        public string id { owned get { return "google-chat"; } }
        public string name { owned get { return "Google Chat"; } }
        public string icon_name { owned get { return "singularity-account-google-symbolic"; } }

        public async Gee.List<Channel> discover () throws Error {
            var list = new Gee.ArrayList<Channel> ();
            foreach (var a in Manager.get_default ().get_accounts_for (Capability.CHAT)) {
                if (a.provider == "google") list.add (new GoogleChatChannel (a));
            }
            return list;
        }
    }

    public class GoogleChatChannel : Channel {
        private Rest rest;
        private string base_url;
        private Gee.HashMap<string, string> names = new Gee.HashMap<string, string> ();
        private Gee.HashMap<string, string> update_times = new Gee.HashMap<string, string> ();

        public GoogleChatChannel (Account account) {
            Object (id: "google-chat:" + account.id, provider_id: "google-chat");
            account_id = account.id;
            title = account.display_name;
            icon_name = "singularity-account-google-symbolic";
            base_url = account.get_endpoint ("google-chat") ?? "https://chat.googleapis.com/v1/";
            features = Features.ATTACHMENTS | Features.REPLIES | Features.EDIT | Features.DELETE | Features.REACTIONS | Features.READ_MARKERS | Features.NEW_CONVERSATION;
            realtime = Realtime.POLL;
            poll_seconds = 20;
            rest = new Rest (account);
        }

        private async void ensure_self (Cancellable? cancel) throws Error {
            if (self_id != "") return;
            var r = yield rest.ok ("GET", "https://openidconnect.googleapis.com/v1/userinfo", null, null, cancel);
            string sub = Rest.str (r.object (), "sub");
            if (sub != "") self_id = "users/" + sub;
        }

        private static int64 time_of (Json.Object o, string member) {
            return Rest.iso_time (Rest.str (o, member));
        }

        private async string direct_title (string space, Cancellable? cancel) {
            if (names.has_key (space)) return names[space];
            string title = _("Direct Message");
            try {
                var r = yield rest.ok ("GET", base_url + space + "/members?pageSize=10", null, null, cancel);
                foreach (var n in r.array_member ("memberships").get_elements ()) {
                    var member = Rest.obj (n.get_object (), "member");
                    if (member == null || Rest.str (member, "name") == self_id) continue;
                    string dn = Rest.str (member, "displayName");
                    if (dn != "") {
                        title = dn;
                        break;
                    }
                }
            } catch (Error e) {
            }
            names[space] = title;
            return title;
        }

        public override async Gee.List<Conversation> conversations (Cancellable? cancel = null) throws Error {
            yield ensure_self (cancel);
            var list = new Gee.ArrayList<Conversation> ();
            string token = "";
            do {
                string url = base_url + "spaces?pageSize=100" + (token != "" ? "&pageToken=" + Uri.escape_string (token, null, false) : "");
                var r = yield rest.ok ("GET", url, null, null, cancel);
                foreach (var n in r.array_member ("spaces").get_elements ()) {
                    var o = n.get_object ();
                    var c = new Conversation ();
                    c.id = Rest.str (o, "name");
                    string type = Rest.str (o, "spaceType", Rest.str (o, "type"));
                    c.kind = type == "DIRECT_MESSAGE" || type == "DM" ? ConversationKind.DIRECT : type == "SPACE" ? ConversationKind.CHANNEL : ConversationKind.GROUP;
                    c.title = Rest.str (o, "displayName");
                    if (c.title == "") c.title = yield direct_title (c.id, cancel);
                    c.activity = time_of (o, "lastActiveTime");
                    list.add (c);
                }
                token = Rest.str (r.object (), "nextPageToken");
            } while (token != "" && list.size < 500);
            yield fill_read_state (list, cancel);
            return list;
        }

        private async void fill_read_state (Gee.List<Conversation> list, Cancellable? cancel) {
            foreach (var c in list) {
                try {
                    var r = yield rest.ok ("GET", base_url + "users/me/" + c.id + "/spaceReadState", null, null, cancel);
                    int64 read = time_of (r.object (), "lastReadTime");
                    c.unread = c.activity > read && read > 0 ? 1 : 0;
                } catch (Error e) {
                }
            }
        }

        private Message parse (Json.Object o, string conversation) {
            var m = new Message ();
            m.id = Rest.str (o, "name");
            m.conversation = conversation;
            var sender = Rest.obj (o, "sender");
            if (sender != null) {
                m.author_id = Rest.str (sender, "name");
                m.author_name = Rest.str (sender, "displayName", m.author_id);
            }
            m.outgoing = m.author_id != "" && m.author_id == self_id;
            m.time = time_of (o, "createTime");
            m.text = Rest.str (o, "text", Rest.str (o, "argumentText"));
            m.deleted = Rest.str (o, "deleteTime") != "";
            m.edited = Rest.str (o, "lastUpdateTime") != "" && Rest.str (o, "lastUpdateTime") != Rest.str (o, "createTime");
            update_times[m.id] = Rest.str (o, "lastUpdateTime", Rest.str (o, "createTime"));
            var quoted = Rest.obj (o, "quotedMessageMetadata");
            if (quoted != null) m.reply_to = Rest.str (quoted, "name");
            foreach (var n in Rest.arr (o, "attachment").get_elements ()) {
                var at = n.get_object ();
                var a = new Attachment ();
                a.name = Rest.str (at, "contentName");
                a.mime = Rest.str (at, "contentType");
                a.url = Rest.str (at, "downloadUri");
                var data_ref = Rest.obj (at, "attachmentDataRef");
                if (data_ref != null && Rest.str (data_ref, "resourceName") != "") {
                    a.url = "https://chat.googleapis.com/v1/media/%s?alt=media".printf (Rest.str (data_ref, "resourceName"));
                }
                m.attachments.add (a);
            }
            foreach (var n in Rest.arr (o, "emojiReactionSummaries").get_elements ()) {
                var s = n.get_object ();
                var emoji = Rest.obj (s, "emoji");
                if (emoji == null) continue;
                string u = Rest.str (emoji, "unicode");
                if (u != "") m.reactions[u] = (int) Rest.num (s, "reactionCount", 1);
            }
            return m;
        }

        public override async Gee.List<Message> messages (string conversation, string? after, int limit, Cancellable? cancel = null) throws Error {
            yield ensure_self (cancel);
            var q = new HashTable<string, string> (str_hash, str_equal);
            q["pageSize"] = limit.clamp (1, 100).to_string ();
            q["orderBy"] = "createTime desc";
            q["showDeleted"] = "true";
            if (after != null && after != "" && update_times.has_key (after)) q["filter"] = "createTime > \"%s\"".printf (update_times[after]);
            var r = yield rest.ok ("GET", Rest.query (base_url + conversation + "/messages", q), null, null, cancel);
            var items = r.array_member ("messages").get_elements ();
            var list = new Gee.ArrayList<Message> ();
            for (int i = (int) items.length () - 1; i >= 0; i--) list.add (parse (items.nth_data (i).get_object (), conversation));
            return list;
        }

        private Json.Object message_body (string text, string? reply_to) {
            var body = new Json.Object ();
            body.set_string_member ("text", text);
            if (reply_to != null && reply_to != "" && update_times.has_key (reply_to)) {
                var q = new Json.Object ();
                q.set_string_member ("name", reply_to);
                q.set_string_member ("lastUpdateTime", update_times[reply_to]);
                body.set_object_member ("quotedMessageMetadata", q);
            }
            return body;
        }

        public override async Message send (string conversation, string text, string? reply_to, Cancellable? cancel = null) throws Error {
            yield ensure_self (cancel);
            var r = yield rest.json ("POST", base_url + conversation + "/messages", message_body (text, reply_to), cancel);
            return parse (r.object (), conversation);
        }

        public override async void mark_read (string conversation, string message, Cancellable? cancel = null) throws Error {
            var body = new Json.Object ();
            body.set_string_member ("lastReadTime", new DateTime.now_utc ().format_iso8601 ());
            yield rest.json ("PATCH", base_url + "users/me/" + conversation + "/spaceReadState?updateMask=lastReadTime", body, cancel);
        }

        public override async void edit (string conversation, string message, string text, Cancellable? cancel = null) throws Error {
            var body = new Json.Object ();
            body.set_string_member ("text", text);
            yield rest.json ("PATCH", base_url + message + "?updateMask=text", body, cancel);
        }

        public override async void remove (string conversation, string message, Cancellable? cancel = null) throws Error {
            yield rest.ok ("DELETE", base_url + message, null, null, cancel);
        }

        public override async void react (string conversation, string message, string emoji, bool add, Cancellable? cancel = null) throws Error {
            if (add) {
                var e = new Json.Object ();
                e.set_string_member ("unicode", emoji);
                var body = new Json.Object ();
                body.set_object_member ("emoji", e);
                yield rest.json ("POST", base_url + message + "/reactions", body, cancel);
                return;
            }
            yield ensure_self (cancel);
            string filter = "emoji.unicode = \"%s\" AND user.name = \"%s\"".printf (emoji, self_id);
            var r = yield rest.ok ("GET", base_url + message + "/reactions?filter=" + Uri.escape_string (filter, null, false), null, null, cancel);
            foreach (var n in r.array_member ("reactions").get_elements ()) {
                yield rest.ok ("DELETE", base_url + Rest.str (n.get_object (), "name"), null, null, cancel);
            }
        }

        public override async string start (string peer, Cancellable? cancel = null) throws Error {
            string user = peer.has_prefix ("users/") ? peer : "users/" + peer;
            var found = yield rest.call ("GET", base_url + "spaces:findDirectMessage?name=" + Uri.escape_string (user, null, false), null, null, cancel);
            if (found.status == 200 && Rest.str (found.object (), "name") != "") return Rest.str (found.object (), "name");
            var space = new Json.Object ();
            space.set_string_member ("spaceType", "DIRECT_MESSAGE");
            var member = new Json.Object ();
            member.set_string_member ("name", user);
            member.set_string_member ("type", "HUMAN");
            var membership = new Json.Object ();
            membership.set_object_member ("member", member);
            var memberships = new Json.Array ();
            memberships.add_object_element (membership);
            var body = new Json.Object ();
            body.set_object_member ("space", space);
            body.set_array_member ("memberships", memberships);
            var r = yield rest.json ("POST", base_url + "spaces:setup", body, cancel);
            return Rest.str (r.object (), "name");
        }

        public override async Bytes? download (Attachment attachment, Cancellable? cancel = null) throws Error {
            if (attachment.url == "") return null;
            var r = yield rest.http.send ("GET", attachment.url, null, null, null, cancel);
            return r.ok ? r.body : null;
        }
    }
}
