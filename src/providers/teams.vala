using Singularity.Accounts;
using Singularity.Messaging;

namespace Singularity.Apps.Messages {

    public class TeamsProvider : Object, Provider {
        public string id { owned get { return "teams"; } }
        public string name { owned get { return "Microsoft Teams"; } }
        public string icon_name { owned get { return "singularity-account-microsoft-symbolic"; } }

        public async Gee.List<Channel> discover () throws Error {
            var list = new Gee.ArrayList<Channel> ();
            foreach (var a in Manager.get_default ().get_accounts_for (Capability.CHAT)) {
                if (a.provider == "microsoft") list.add (new TeamsChannel (a));
            }
            return list;
        }
    }

    public class TeamsChannel : Channel {
        private const string GRAPH = "https://graph.microsoft.com/v1.0/";

        private Account account;
        private Rest rest;
        private string tenant = "";
        private Gee.HashMap<string, int64?> times = new Gee.HashMap<string, int64?> ();

        public TeamsChannel (Account account) {
            Object (id: "teams:" + account.id, provider_id: "teams");
            this.account = account;
            account_id = account.id;
            title = account.display_name;
            icon_name = "singularity-account-microsoft-symbolic";
            features = Features.ATTACHMENTS | Features.EDIT | Features.DELETE | Features.REACTIONS | Features.READ_MARKERS | Features.NEW_CONVERSATION;
            realtime = Realtime.POLL;
            poll_seconds = 20;
            rest = new Rest (account);
        }

        private async void ensure_self (Cancellable? cancel) throws Error {
            if (self_id != "") return;
            var r = yield rest.ok ("GET", GRAPH + "me?$select=id,displayName", null, null, cancel);
            self_id = Rest.str (r.object (), "id");
            var creds = yield account.get_credentials (Capability.CHAT);
            tenant = tenant_of (creds.secret);
        }

        private static string tenant_of (string jwt) {
            string[] parts = jwt.split (".");
            if (parts.length < 2) return "";
            string b = parts[1].replace ("-", "+").replace ("_", "/");
            while (b.length % 4 != 0) b += "=";
            try {
                var parser = new Json.Parser ();
                parser.load_from_data ((string) Base64.decode (b));
                return Rest.str (parser.get_root ().get_object (), "tid");
            } catch (Error e) {
                return "";
            }
        }

        public string photo_url (string user) {
            return user != "" ? GRAPH + "users/%s/photos/96x96/$value".printf (esc (user)) : "";
        }

        private static string esc (string s) {
            return Uri.escape_string (s, null, false);
        }

        public override async Gee.List<Conversation> conversations (Cancellable? cancel = null) throws Error {
            yield ensure_self (cancel);
            var list = new Gee.ArrayList<Conversation> ();
            string url = GRAPH + "me/chats?$expand=members,lastMessagePreview&$top=50&$orderby=lastMessagePreview/createdDateTime%20desc";
            int pages = 0;
            while (url != "" && pages++ < 4) {
                var r = yield rest.ok ("GET", url, null, null, cancel);
                foreach (var n in r.array_member ("value").get_elements ()) {
                    var o = n.get_object ();
                    var hidden_view = Rest.obj (o, "viewpoint");
                    if (hidden_view != null && hidden_view.has_member ("isHidden") && hidden_view.get_boolean_member ("isHidden")) continue;
                    var c = new Conversation ();
                    c.id = Rest.str (o, "id");
                    string type = Rest.str (o, "chatType");
                    c.kind = type == "oneOnOne" ? ConversationKind.DIRECT : ConversationKind.GROUP;
                    string[] others = {};
                    foreach (var mn in Rest.arr (o, "members").get_elements ()) {
                        var mo = mn.get_object ();
                        if (Rest.str (mo, "userId") == self_id) continue;
                        string dn = Rest.str (mo, "displayName");
                        if (dn != "") others += dn;
                        if (c.kind == ConversationKind.DIRECT) {
                            c.peer = Rest.str (mo, "email", Rest.str (mo, "userId"));
                            c.avatar_url = photo_url (Rest.str (mo, "userId"));
                        }
                    }
                    c.title = Rest.str (o, "topic");
                    if (c.title == "") c.title = others.length > 0 ? string.joinv (", ", others) : _("Chat");
                    c.activity = Rest.iso_time (Rest.str (o, "lastUpdatedDateTime"));
                    var preview = Rest.obj (o, "lastMessagePreview");
                    if (preview != null) {
                        var body = Rest.obj (preview, "body");
                        if (body != null) c.last_preview = Rest.strip_html (Rest.str (body, "content")).replace ("\n", " ");
                        int64 created = Rest.iso_time (Rest.str (preview, "createdDateTime"));
                        if (created > c.activity) c.activity = created;
                        var from = Rest.obj (preview, "from");
                        var user = from != null ? Rest.obj (from, "user") : null;
                        if (user != null) c.last_author = Rest.str (user, "id") == self_id ? _("You") : Rest.str (user, "displayName");
                        var view = Rest.obj (o, "viewpoint");
                        int64 read = view != null ? Rest.iso_time (Rest.str (view, "lastMessageReadDateTime")) : 0;
                        bool mine = user != null && Rest.str (user, "id") == self_id;
                        c.unread = !mine && created > read ? 1 : 0;
                    }
                    list.add (c);
                }
                url = Rest.str (r.object (), "@odata.nextLink");
            }
            return list;
        }

        private Message parse (Json.Object o, string conversation) {
            var m = new Message ();
            m.id = Rest.str (o, "id");
            m.conversation = conversation;
            m.time = Rest.iso_time (Rest.str (o, "createdDateTime"));
            times[m.id] = m.time;
            var from = Rest.obj (o, "from");
            var user = from != null ? Rest.obj (from, "user") : null;
            if (user != null) {
                m.author_id = Rest.str (user, "id");
                m.author_name = Rest.str (user, "displayName");
            }
            m.outgoing = m.author_id != "" && m.author_id == self_id;
            m.system = Rest.str (o, "messageType") != "message";
            m.deleted = Rest.str (o, "deletedDateTime") != "";
            m.edited = Rest.str (o, "lastEditedDateTime") != "";
            var body = Rest.obj (o, "body");
            if (body != null && Rest.str (body, "contentType") == "html") {
                string html = Rest.str (body, "content");
                m.text = Rest.strip_html (html);
                try {
                    MatchInfo mi;
                    var re = new Regex ("<img[^>]*src=\"([^\"]*/hostedContents/[^\"]*)\"", RegexCompileFlags.CASELESS);
                    for (re.match (html, 0, out mi); mi.matches (); mi.next ()) {
                        var a = new Attachment ();
                        a.name = _("Image");
                        a.url = mi.fetch (1).replace ("&amp;", "&");
                        a.mime = "image/png";
                        m.attachments.add (a);
                    }
                } catch (RegexError e) {
                }
            } else if (body != null) {
                m.text = Rest.str (body, "content");
            }
            if (m.system && m.text == "") m.text = _("Conversation updated");
            foreach (var n in Rest.arr (o, "attachments").get_elements ()) {
                var at = n.get_object ();
                string kind = Rest.str (at, "contentType");
                if (kind == "messageReference") {
                    m.reply_to = Rest.str (at, "id");
                    continue;
                }
                var a = new Attachment ();
                a.name = Rest.str (at, "name");
                a.url = Rest.str (at, "contentUrl");
                a.mime = kind == "reference" ? "" : kind;
                m.attachments.add (a);
            }
            try {
                m.text = new Regex ("<attachment id=\"[^\"]*\"></attachment>").replace (m.text, -1, 0, "").strip ();
            } catch (RegexError e) {
            }
            foreach (var n in Rest.arr (o, "reactions").get_elements ()) {
                var ro = n.get_object ();
                string emoji = Rest.str (ro, "displayName", Rest.str (ro, "reactionType"));
                if (emoji == "") continue;
                m.reactions[emoji] = m.reactions.has_key (emoji) ? m.reactions[emoji] + 1 : 1;
                var u = Rest.obj (ro, "user");
                var uu = u != null ? Rest.obj (u, "user") : null;
                if (uu != null && Rest.str (uu, "id") == self_id) m.own_reactions.add (emoji);
            }
            return m;
        }

        public override async Gee.List<Message> messages (string conversation, string? after, int limit, Cancellable? cancel = null) throws Error {
            yield ensure_self (cancel);
            var r = yield rest.ok ("GET", GRAPH + "chats/%s/messages?$top=%d".printf (esc (conversation), limit.clamp (1, 50)), null, null, cancel);
            var items = r.array_member ("value").get_elements ();
            int64 floor = after != null && times.has_key (after) ? times[after] : -1;
            var list = new Gee.ArrayList<Message> ();
            for (int i = (int) items.length () - 1; i >= 0; i--) {
                var m = parse (items.nth_data (i).get_object (), conversation);
                if (floor >= 0 && m.time < floor) continue;
                list.add (m);
            }
            return list;
        }

        private static Json.Object text_body (string text) {
            var b = new Json.Object ();
            b.set_string_member ("contentType", "text");
            b.set_string_member ("content", text);
            var body = new Json.Object ();
            body.set_object_member ("body", b);
            return body;
        }

        public override async Message send (string conversation, string text, string? reply_to, Cancellable? cancel = null) throws Error {
            yield ensure_self (cancel);
            var r = yield rest.json ("POST", GRAPH + "chats/%s/messages".printf (esc (conversation)), text_body (text), cancel);
            return parse (r.object (), conversation);
        }

        public override async Message upload (string conversation, File file, string caption, Cancellable? cancel = null) throws Error {
            var files = new Gee.ArrayList<File> ();
            files.add (file);
            return yield send_images (conversation, files, caption, cancel);
        }

        public async Message send_images (string conversation, Gee.List<File> files, string text, Cancellable? cancel = null) throws Error {
            yield ensure_self (cancel);
            var html = new StringBuilder ();
            var hosted = new Json.Array ();
            int n = 0;
            foreach (var file in files) {
                var info = yield file.query_info_async (FileAttribute.STANDARD_CONTENT_TYPE, FileQueryInfoFlags.NONE, Priority.DEFAULT, cancel);
                string type = ContentType.get_mime_type (info.get_content_type () ?? "") ?? "";
                if (!type.has_prefix ("image/")) throw new MessagingError.NOT_SUPPORTED (_("Teams chats only accept images here: %s").printf (file.get_basename ()));
                uint8[] data;
                yield file.load_contents_async (cancel, out data, null);
                n++;
                var h = new Json.Object ();
                h.set_string_member ("@microsoft.graph.temporaryId", n.to_string ());
                h.set_string_member ("contentBytes", Base64.encode (data));
                h.set_string_member ("contentType", type);
                hosted.add_object_element (h);
                html.append ("<p><img src=\"../hostedContents/%d/$value\"></p>".printf (n));
            }
            if (text.strip () != "") html.append ("<p>%s</p>".printf (Markup.escape_text (text.strip ()).replace ("\n", "<br>")));
            var b = new Json.Object ();
            b.set_string_member ("contentType", "html");
            b.set_string_member ("content", html.str);
            var body = new Json.Object ();
            body.set_object_member ("body", b);
            body.set_array_member ("hostedContents", hosted);
            var r = yield rest.json ("POST", GRAPH + "chats/%s/messages".printf (esc (conversation)), body, cancel);
            return parse (r.object (), conversation);
        }

        public async void hide_chat (string conversation, Cancellable? cancel = null) throws Error {
            yield ensure_self (cancel);
            var user = new Json.Object ();
            user.set_string_member ("id", self_id);
            if (tenant != "") user.set_string_member ("tenantId", tenant);
            var body = new Json.Object ();
            body.set_object_member ("user", user);
            yield rest.json ("POST", GRAPH + "chats/%s/hideForUser".printf (esc (conversation)), body, cancel);
        }

        public override async void edit (string conversation, string message, string text, Cancellable? cancel = null) throws Error {
            yield rest.json ("PATCH", GRAPH + "chats/%s/messages/%s".printf (esc (conversation), esc (message)), text_body (text), cancel);
        }

        public override async void remove (string conversation, string message, Cancellable? cancel = null) throws Error {
            yield ensure_self (cancel);
            yield rest.json ("POST", GRAPH + "users/%s/chats/%s/messages/%s/softDelete".printf (esc (self_id), esc (conversation), esc (message)), new Json.Object (), cancel);
        }

        public override async void react (string conversation, string message, string emoji, bool add, Cancellable? cancel = null) throws Error {
            var body = new Json.Object ();
            body.set_string_member ("reactionType", emoji);
            yield rest.json ("POST", GRAPH + "chats/%s/messages/%s/%s".printf (esc (conversation), esc (message), add ? "setReaction" : "unsetReaction"), body, cancel);
        }

        public override async void mark_read (string conversation, string message, Cancellable? cancel = null) throws Error {
            yield ensure_self (cancel);
            var user = new Json.Object ();
            user.set_string_member ("id", self_id);
            if (tenant != "") user.set_string_member ("tenantId", tenant);
            var body = new Json.Object ();
            body.set_object_member ("user", user);
            yield rest.json ("POST", GRAPH + "chats/%s/markChatReadForUser".printf (esc (conversation)), body, cancel);
        }

        private static Json.Object member (string user) {
            var o = new Json.Object ();
            o.set_string_member ("@odata.type", "#microsoft.graph.aadUserConversationMember");
            var roles = new Json.Array ();
            roles.add_string_element ("owner");
            o.set_array_member ("roles", roles);
            o.set_string_member ("user@odata.bind", "https://graph.microsoft.com/v1.0/users('%s')".printf (user));
            return o;
        }

        public override async string start (string peer, Cancellable? cancel = null) throws Error {
            yield ensure_self (cancel);
            var members = new Json.Array ();
            members.add_object_element (member (self_id));
            members.add_object_element (member (peer));
            var body = new Json.Object ();
            body.set_string_member ("chatType", "oneOnOne");
            body.set_array_member ("members", members);
            var r = yield rest.json ("POST", GRAPH + "chats", body, cancel);
            return Rest.str (r.object (), "id");
        }

        public override async Gee.List<Peer> search_people (string query, Cancellable? cancel = null) throws Error {
            var list = new Gee.ArrayList<Peer> ();
            var r = yield rest.call ("GET", GRAPH + "me/people?$top=15&$search=" + esc ("\"" + query + "\""), null, null, cancel);
            if (r.status != 200) return list;
            foreach (var n in r.array_member ("value").get_elements ()) {
                var o = n.get_object ();
                string upn = Rest.str (o, "userPrincipalName");
                if (upn == "") continue;
                list.add (new Peer (upn, Rest.str (o, "displayName", upn), upn));
            }
            return list;
        }

        public override async Bytes? download (Attachment attachment, Cancellable? cancel = null) throws Error {
            if (attachment.url == "" || !attachment.url.has_prefix (GRAPH)) return null;
            var r = yield rest.http.send ("GET", attachment.url, null, null, null, cancel);
            return r.ok ? r.body : null;
        }
    }
}
