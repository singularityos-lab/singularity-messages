using Singularity.Messaging;

namespace Singularity.Apps.Messages {

    public class Entry : Object {
        public Channel channel { get; construct; }
        public Conversation conversation { get; construct; }

        public Entry (Channel channel, Conversation conversation) {
            Object (channel: channel, conversation: conversation);
        }

        public string key {
            owned get { return Engine.key_of (channel.id, conversation.id); }
        }
    }

    public class Engine : Object {
        private const int PAGE = 50;

        public Store store { get; construct; }

        private Gee.ArrayList<Provider> providers = new Gee.ArrayList<Provider> ();
        private Gee.HashMap<string, Channel> channels = new Gee.HashMap<string, Channel> ();
        private Gee.ArrayList<string> order = new Gee.ArrayList<string> ();
        private Gee.HashMap<string, Gee.HashMap<string, Conversation>> convs = new Gee.HashMap<string, Gee.HashMap<string, Conversation>> ();
        private Gee.HashMap<string, Gee.ArrayList<Message>> cache = new Gee.HashMap<string, Gee.ArrayList<Message>> ();
        private Gee.HashMap<string, uint> timers = new Gee.HashMap<string, uint> ();
        private Gee.HashSet<string> refreshing = new Gee.HashSet<string> ();
        private Gee.HashSet<string> refresh_again = new Gee.HashSet<string> ();
        private Gee.HashSet<string> loaded_once = new Gee.HashSet<string> ();
        private Gee.HashSet<string> dirty = new Gee.HashSet<string> ();
        private string focus_channel = "";
        private string focus_conversation = "";
        private bool focus_visible = false;
        private Cancellable? wait_cancel = null;
        private uint focus_timer = 0;
        private uint retry_timer = 0;
        private uint save_timer = 0;
        private int64 started;
        private bool discovering = false;
        private bool discover_again = false;

        public signal void channels_changed ();
        public signal void conversations_changed ();
        public signal void messages_changed (string channel, string conversation);
        public signal void problem (string channel, string message);
        public signal void arrived (Channel channel, Conversation conversation, Message message);
        public signal void received (Channel channel, string conversation, Message message);

        public Engine (Store store) {
            Object (store: store);
            started = get_real_time () / 1000000;
            NetworkMonitor.get_default ().network_changed.connect ((up) => {
                if (up) retry_failed ();
            });
            retry_timer = Timeout.add_seconds (60, () => {
                retry_failed ();
                return Source.CONTINUE;
            });
        }

        public static string key_of (string channel, string conversation) {
            return channel + "\n" + conversation;
        }

        public void add_provider (Provider p) {
            foreach (var existing in providers) if (existing.id == p.id) return;
            providers.add (p);
            p.channels_changed.connect (() => discover.begin ());
        }

        public void remove_provider (Provider p) {
            providers.remove (p);
            discover.begin ();
        }

        public Gee.List<Channel> get_channels () {
            var list = new Gee.ArrayList<Channel> ();
            foreach (string id in order) if (channels.has_key (id)) list.add (channels[id]);
            return list;
        }

        public Channel? channel (string id) {
            return channels[id];
        }

        public Conversation? find_conversation (string channel, string id) {
            var map = convs[channel];
            return map != null ? map[id] : null;
        }

        public async void discover () {
            if (discovering) {
                discover_again = true;
                return;
            }
            discovering = true;
            do {
                discover_again = false;
                var seen = new Gee.HashSet<string> ();
                foreach (var p in providers.to_array ()) {
                    Gee.List<Channel> found;
                    try {
                        found = yield p.discover ();
                    } catch (Error e) {
                        warning ("messages: %s: %s", p.id, e.message);
                        continue;
                    }
                    bool added = false;
                    foreach (var ch in found) {
                        seen.add (ch.id);
                        if (!channels.has_key (ch.id)) {
                            adopt (ch);
                            added = true;
                        }
                    }
                    if (added) channels_changed ();
                }
                foreach (var id in channels.keys.to_array ()) {
                    if (!seen.contains (id)) drop (id);
                }
            } while (discover_again);
            discovering = false;
            channels_changed ();
            conversations_changed ();
        }

        private void adopt (Channel ch) {
            channels[ch.id] = ch;
            if (!order.contains (ch.id)) order.add (ch.id);
            var map = new Gee.HashMap<string, Conversation> ();
            foreach (var c in store.load_conversations (ch.id)) map[c.id] = c;
            convs[ch.id] = map;
            ch.incoming.connect ((conv, list) => merge (ch, conv, list, true));
            ch.conversations_changed.connect (() => refresh.begin (ch));
            schedule (ch);
            refresh.begin (ch);
        }

        private void drop (string id) {
            var ch = channels[id];
            channels.unset (id);
            order.remove (id);
            convs.unset (id);
            uint t;
            if (timers.unset (id, out t)) Source.remove (t);
            if (ch != null) ch.close ();
            if (focus_channel == id) focus ("", "", false);
        }

        private void schedule (Channel ch) {
            uint t;
            if (timers.unset (ch.id, out t)) Source.remove (t);
            string id = ch.id;
            timers[id] = Timeout.add_seconds (uint.max (10, ch.poll_seconds), () => {
                var c = channels[id];
                if (c != null) refresh.begin (c);
                return Source.CONTINUE;
            });
        }

        public void refresh_all () {
            foreach (var ch in channels.values) refresh.begin (ch);
        }

        public async void refresh (Channel ch) {
            if (refreshing.contains (ch.id)) {
                refresh_again.add (ch.id);
                return;
            }
            refreshing.add (ch.id);
            try {
                var fresh = yield ch.conversations ();
                var map = convs[ch.id];
                if (map == null) return;
                bool first = !loaded_once.contains (ch.id);
                loaded_once.add (ch.id);
                var next = new Gee.HashMap<string, Conversation> ();
                var changed = new Gee.ArrayList<Conversation> ();
                foreach (var c in fresh) {
                    var old = map[c.id];
                    if (old != null && c.last_preview == "" && old.last_preview != "") {
                        c.last_preview = old.last_preview;
                        c.last_author = old.last_author;
                    }
                    if (old != null && c.avatar_url == "") c.avatar_url = old.avatar_url;
                    if (!first && c.unread > 0 && (old == null || c.activity > old.activity || c.unread > old.unread)) changed.add (c);
                    next[c.id] = c;
                }
                foreach (var e in map.entries) {
                    if (!next.has_key (e.key) && e.value.activity == 0) next[e.key] = e.value;
                }
                convs[ch.id] = next;
                store.save_conversations (ch.id, next.values);
                if (ch.attention == "" || ch.attention.has_prefix ("!")) ch.attention = "";
                conversations_changed ();
                foreach (var c in changed) yield fetch_new (ch, c.id, true);
                if (focus_channel == ch.id && focus_conversation != "" && ch.realtime == Realtime.PUSH) yield fetch_new (ch, focus_conversation, true);
            } catch (Error e) {
                ch.attention = "!" + e.message;
                problem (ch.id, e.message);
                conversations_changed ();
            } finally {
                refreshing.remove (ch.id);
            }
            if (refresh_again.remove (ch.id) && channels.has_key (ch.id)) yield refresh (ch);
        }

        public Gee.List<Entry> entries (string? channel_filter = null, string query = "") {
            var list = new Gee.ArrayList<Entry> ();
            string q = query.down ();
            foreach (var ch in get_channels ()) {
                if (channel_filter != null && channel_filter != "" && ch.id != channel_filter) continue;
                var map = convs[ch.id];
                if (map == null) continue;
                foreach (var c in map.values) {
                    if (q != "" && !c.title.down ().contains (q) && !c.last_preview.down ().contains (q)) continue;
                    list.add (new Entry (ch, c));
                }
            }
            list.sort ((a, b) => {
                int64 x = a.conversation.activity, y = b.conversation.activity;
                return x > y ? -1 : (x < y ? 1 : strcmp (a.conversation.title, b.conversation.title));
            });
            return list;
        }

        public Gee.List<Entry> search_messages (string query, int limit = 50) {
            var list = new Gee.ArrayList<Entry> ();
            string q = query.down ().strip ();
            if (q == "") return list;
            foreach (var ch in channels.values) {
                var map = convs[ch.id];
                if (map == null) continue;
                foreach (var c in map.values) {
                    foreach (var m in messages (ch.id, c.id)) {
                        if (m.text.down ().contains (q)) {
                            list.add (new Entry (ch, c));
                            break;
                        }
                    }
                    if (list.size >= limit) return list;
                }
            }
            return list;
        }

        public int unread_total () {
            int n = 0;
            foreach (var map in convs.values) foreach (var c in map.values) if (c.counts) n += c.unread;
            return n;
        }

        public Gee.ArrayList<Message> messages (string channel, string conversation) {
            string k = key_of (channel, conversation);
            var list = cache[k];
            if (list == null) {
                list = store.load_messages (channel, conversation);
                cache[k] = list;
            }
            return list;
        }

        private static string last_remote_id (Gee.List<Message> list) {
            for (int i = list.size - 1; i >= 0; i--) {
                var m = list[i];
                if (m.state == MessageState.SENT && m.id != "" && !m.id.has_prefix ("pending-") && !m.id.has_prefix ("local-")) return m.id;
            }
            return "";
        }

        public async void load (Channel ch, string conversation) {
            try {
                var list = yield ch.messages (conversation, null, PAGE);
                merge (ch, conversation, list, false);
            } catch (Error e) {
                problem (ch.id, e.message);
            }
        }

        private async void fetch_new (Channel ch, string conversation, bool notify) {
            var known = messages (ch.id, conversation);
            string after = last_remote_id (known);
            try {
                var list = yield ch.messages (conversation, after == "" ? null : after, PAGE);
                merge (ch, conversation, list, notify);
            } catch (Error e) {
                problem (ch.id, e.message);
            }
        }

        private static bool echoes (Message local, Message remote) {
            bool placeholder = (local.id.has_prefix ("pending-") && local.state == MessageState.PENDING)
                || (local.id.has_prefix ("local-") && local.outgoing);
            if (!placeholder) return false;
            if (remote.time > 0 && local.time > 0 && (remote.time - local.time).abs () > 600) return false;
            if (local.attachments.size > 0 && remote.attachments.size > 0) return local.attachments[0].name == remote.attachments[0].name;
            return local.attachments.size == 0 && remote.attachments.size == 0 && local.text.strip () == remote.text.strip ();
        }

        public void merge (Channel ch, string conversation, Gee.List<Message> incoming, bool notify) {
            if (incoming.size == 0) return;
            var list = messages (ch.id, conversation);
            var index = new Gee.HashMap<string, int> ();
            for (int i = 0; i < list.size; i++) index[list[i].id] = i;
            var fresh = new Gee.ArrayList<Message> ();
            foreach (var m in incoming) {
                m.conversation = conversation;
                if (index.has_key (m.id)) {
                    list[index[m.id]] = m;
                    continue;
                }
                if (m.outgoing) {
                    bool replaced = false;
                    for (int i = 0; i < list.size; i++) {
                        var p = list[i];
                        if (echoes (p, m)) {
                            list[i] = m;
                            replaced = true;
                            break;
                        }
                    }
                    if (replaced) continue;
                }
                list.add (m);
                index[m.id] = list.size - 1;
                fresh.add (m);
            }
            list.sort ((a, b) => {
                bool pa = a.state != MessageState.SENT, pb = b.state != MessageState.SENT;
                if (pa != pb) return pa ? 1 : -1;
                return a.time < b.time ? -1 : (a.time > b.time ? 1 : 0);
            });
            while (list.size > Store.KEEP) list.remove_at (0);
            var c = update_preview (ch, conversation);
            mark_dirty (ch.id, conversation);
            messages_changed (ch.id, conversation);
            foreach (var m in fresh) {
                if (!m.outgoing && !m.system && m.time >= started - 120) received (ch, conversation, m);
            }
            bool focused = focus_visible && focus_channel == ch.id && focus_conversation == conversation;
            if (focused && c != null && (c.unread > 0 || fresh.size > 0)) mark_read.begin (ch, conversation, true);
            if (!notify || c == null) return;
            foreach (var m in fresh) {
                if (m.outgoing || m.system || m.time < started - 120) continue;
                if (focused) continue;
                arrived (ch, c, m);
            }
            conversations_changed ();
        }

        private Conversation? update_preview (Channel ch, string conversation) {
            var c = find_conversation (ch.id, conversation);
            var list = messages (ch.id, conversation);
            if (c == null || list.size == 0) return c;
            Message? last = null;
            for (int i = list.size - 1; i >= 0 && last == null; i--) if (!list[i].system) last = list[i];
            if (last != null) {
                c.last_preview = last.preview ();
                c.last_author = last.outgoing ? _("You") : last.author_name;
                if (last.time > c.activity) c.activity = last.time;
            }
            return c;
        }

        private void mark_dirty (string channel, string conversation) {
            dirty.add (key_of (channel, conversation));
            if (save_timer != 0) return;
            save_timer = Timeout.add (500, () => {
                save_timer = 0;
                flush ();
                return Source.REMOVE;
            });
        }

        public void flush () {
            foreach (string k in dirty) {
                string[] parts = k.split ("\n", 2);
                var list = cache[k];
                if (list != null && parts.length == 2) store.save_messages (parts[0], parts[1], list);
            }
            dirty.clear ();
            foreach (var e in convs.entries) store.save_conversations (e.key, e.value.values);
        }

        public void focus (string channel, string conversation, bool visible) {
            bool same = channel == focus_channel && conversation == focus_conversation;
            focus_visible = visible;
            if (same && wait_cancel != null) {
                if (visible) {
                    var ch = channels[channel];
                    if (ch != null) mark_read.begin (ch, conversation);
                }
                return;
            }
            if (wait_cancel != null) wait_cancel.cancel ();
            wait_cancel = null;
            if (focus_timer != 0) Source.remove (focus_timer);
            focus_timer = 0;
            focus_channel = channel;
            focus_conversation = conversation;
            var ch = channels[channel];
            if (ch == null || conversation == "") return;
            if (visible) mark_read.begin (ch, conversation);
            wait_cancel = new Cancellable ();
            if (ch.realtime == Realtime.LONG_POLL) {
                long_poll.begin (ch, conversation, wait_cancel);
            } else if (ch.realtime == Realtime.POLL) {
                focus_timer = Timeout.add_seconds (5, () => {
                    fetch_new.begin (ch, conversation, true);
                    return Source.CONTINUE;
                });
            }
        }

        private async void long_poll (Channel ch, string conversation, Cancellable cancel) {
            int failures = 0;
            while (!cancel.is_cancelled ()) {
                string after = last_remote_id (messages (ch.id, conversation));
                if (after == "") {
                    yield load (ch, conversation);
                    after = last_remote_id (messages (ch.id, conversation));
                    if (after == "") {
                        yield sleep (5, cancel);
                        continue;
                    }
                }
                try {
                    bool news = yield ch.wait (conversation, after, cancel);
                    failures = 0;
                    if (news && !cancel.is_cancelled ()) yield fetch_new (ch, conversation, true);
                } catch (Error e) {
                    if (cancel.is_cancelled ()) return;
                    failures++;
                    yield sleep (uint.min (60, 5 * failures), cancel);
                }
            }
        }

        private static async void sleep (uint seconds, Cancellable cancel) {
            uint id = 0;
            ulong handler = 0;
            id = Timeout.add_seconds (seconds, () => {
                id = 0;
                sleep.callback ();
                return Source.REMOVE;
            });
            handler = cancel.connect (() => {
                Idle.add (() => {
                    if (id != 0) {
                        Source.remove (id);
                        id = 0;
                        sleep.callback ();
                    }
                    return Source.REMOVE;
                });
            });
            yield;
            cancel.disconnect (handler);
        }

        public async void mark_read (Channel ch, string conversation, bool force = false) {
            var c = find_conversation (ch.id, conversation);
            if (c == null) return;
            string last = last_remote_id (messages (ch.id, conversation));
            bool had = c.unread > 0 || c.mentioned;
            c.unread = 0;
            c.mentioned = false;
            if (had) conversations_changed ();
            if ((!had && !force) || !ch.supports (Features.READ_MARKERS) || last == "") return;
            try {
                yield ch.mark_read (conversation, last);
            } catch (Error e) {
                debug ("messages: read marker: %s", e.message);
            }
        }

        public void mark_all_read () {
            foreach (var ch in channels.values) {
                var map = convs[ch.id];
                if (map == null) continue;
                foreach (var c in map.values) if (c.unread > 0) mark_read.begin (ch, c.id);
            }
        }

        public async void send (Channel ch, string conversation, string text, string? reply_to) {
            var list = messages (ch.id, conversation);
            var pending = new Message ();
            pending.id = "pending-" + Uuid.string_random ();
            pending.conversation = conversation;
            pending.text = text;
            pending.outgoing = true;
            pending.author_id = ch.self_id;
            pending.time = get_real_time () / 1000000;
            pending.state = MessageState.PENDING;
            pending.reply_to = reply_to ?? "";
            foreach (var m in list) if (reply_to != null && m.id == reply_to) pending.reply_preview = "%s: %s".printf (m.outgoing ? _("You") : m.author_name, m.preview ());
            list.add (pending);
            mark_dirty (ch.id, conversation);
            messages_changed (ch.id, conversation);
            yield deliver (ch, conversation, pending);
        }

        private async void deliver (Channel ch, string conversation, Message pending) {
            var list = messages (ch.id, conversation);
            try {
                var sent = yield ch.send (conversation, pending.text, pending.reply_to != "" ? pending.reply_to : null);
                sent.conversation = conversation;
                sent.outgoing = true;
                if (sent.time == 0) sent.time = pending.time;
                if (sent.reply_preview == "") sent.reply_preview = pending.reply_preview;
                int at = list.index_of (pending);
                bool known = false;
                foreach (var m in list) if (m.id == sent.id && sent.id != "") known = true;
                if (known) {
                    if (at >= 0) list.remove_at (at);
                } else if (at >= 0) {
                    list[at] = sent;
                } else {
                    list.add (sent);
                }
                update_preview (ch, conversation);
                mark_dirty (ch.id, conversation);
                messages_changed (ch.id, conversation);
                conversations_changed ();
            } catch (Error e) {
                pending.state = MessageState.FAILED;
                mark_dirty (ch.id, conversation);
                messages_changed (ch.id, conversation);
                problem (ch.id, _("Not sent: %s").printf (e.message));
            }
        }

        public void retry (Channel ch, string conversation, Message m) {
            if (m.state != MessageState.FAILED) return;
            m.state = MessageState.PENDING;
            messages_changed (ch.id, conversation);
            deliver.begin (ch, conversation, m);
        }

        public void discard (Channel ch, string conversation, Message m) {
            messages (ch.id, conversation).remove (m);
            mark_dirty (ch.id, conversation);
            messages_changed (ch.id, conversation);
        }

        private void retry_failed () {
            foreach (var ch in channels.values) {
                var map = convs[ch.id];
                if (map == null) continue;
                foreach (var c in map.values) {
                    string k = key_of (ch.id, c.id);
                    if (!cache.has_key (k)) continue;
                    foreach (var m in cache[k].to_array ()) if (m.state == MessageState.FAILED) retry (ch, c.id, m);
                }
            }
        }

        public async void upload (Channel ch, string conversation, File file, string caption) {
            try {
                var m = yield ch.upload (conversation, file, caption);
                var batch = new Gee.ArrayList<Message> ();
                if (m.id == "") m.id = "local-" + Uuid.string_random ();
                batch.add (m);
                merge (ch, conversation, batch, false);
                if (ch.realtime != Realtime.PUSH) yield fetch_new (ch, conversation, false);
            } catch (Error e) {
                problem (ch.id, _("Could not send %s: %s").printf (file.get_basename (), e.message));
            }
        }

        public async void edit (Channel ch, string conversation, Message m, string text) {
            string before = m.text;
            m.text = text;
            m.edited = true;
            messages_changed (ch.id, conversation);
            try {
                yield ch.edit (conversation, m.id, text);
                mark_dirty (ch.id, conversation);
            } catch (Error e) {
                m.text = before;
                messages_changed (ch.id, conversation);
                problem (ch.id, e.message);
            }
        }

        public async void remove (Channel ch, string conversation, Message m) {
            try {
                yield ch.remove (conversation, m.id);
                m.deleted = true;
                m.text = "";
                m.attachments.clear ();
                mark_dirty (ch.id, conversation);
                messages_changed (ch.id, conversation);
            } catch (Error e) {
                problem (ch.id, e.message);
            }
        }

        public async void react (Channel ch, string conversation, Message m, string emoji) {
            bool add = !m.own_reactions.contains (emoji);
            try {
                yield ch.react (conversation, m.id, emoji, add);
                int n = m.reactions.has_key (emoji) ? m.reactions[emoji] : 0;
                if (add) {
                    m.own_reactions.add (emoji);
                    m.reactions[emoji] = n + 1;
                } else {
                    m.own_reactions.remove (emoji);
                    if (n <= 1) m.reactions.unset (emoji);
                    else m.reactions[emoji] = n - 1;
                }
                mark_dirty (ch.id, conversation);
                messages_changed (ch.id, conversation);
            } catch (Error e) {
                problem (ch.id, e.message);
            }
        }

        public async string? start (Channel ch, string peer) {
            try {
                string id = yield ch.start (peer);
                yield refresh (ch);
                if (find_conversation (ch.id, id) == null) {
                    var c = new Conversation ();
                    c.id = id;
                    c.title = peer;
                    c.peer = peer;
                    c.activity = get_real_time () / 1000000;
                    convs[ch.id][id] = c;
                    conversations_changed ();
                }
                return id;
            } catch (Error e) {
                problem (ch.id, e.message);
                return null;
            }
        }

        public void shutdown () {
            if (wait_cancel != null) wait_cancel.cancel ();
            flush ();
            foreach (var ch in channels.values) ch.close ();
        }
    }
}
