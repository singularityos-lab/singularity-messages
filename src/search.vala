using Singularity.Messaging;

namespace Singularity.Apps.Messages {

    public class MessagesSearchProvider : Singularity.SearchProviderService {
        private MessagesApp app;

        public MessagesSearchProvider (MessagesApp app) {
            this.app = app;
        }

        private static string query_of (string[] terms) {
            return string.joinv (" ", terms).strip ();
        }

        public override async string[] get_initial_results (string[] terms, Cancellable? cancellable) throws Error {
            string q = query_of (terms);
            if (q.length < 2 || app.engine == null) return {};
            string[] ids = {};
            var seen = new Gee.HashSet<string> ();
            foreach (var e in app.engine.entries (null, q)) {
                if (ids.length >= 8) break;
                ids += e.key;
                seen.add (e.key);
            }
            foreach (var e in app.engine.search_messages (q, 8)) {
                if (ids.length >= 12) break;
                if (seen.add (e.key)) ids += e.key;
            }
            return ids;
        }

        public override async Singularity.SearchResultMeta[] get_result_metas (string[] ids, Cancellable? cancellable) throws Error {
            Singularity.SearchResultMeta[] metas = {};
            foreach (var id in ids) {
                string[] parts = id.split ("\n", 2);
                if (parts.length != 2) continue;
                var ch = app.engine.channel (parts[0]);
                var c = app.engine.find_conversation (parts[0], parts[1]);
                if (ch == null || c == null) continue;
                var meta = new Singularity.SearchResultMeta (id, c.title);
                meta.description = "%s · %s".printf (ch.title, c.last_preview);
                string? avatar = app.avatars.lookup (ch, c);
                meta.icon = avatar != null ? (GLib.Icon) new FileIcon (File.new_for_path (avatar)) : new ThemedIcon ("dev.sinty.messages");
                metas += meta;
            }
            return metas;
        }

        public override async Singularity.SearchActivationReply? activate_result (string id, string[] terms, uint32 timestamp) throws Error {
            string[] parts = id.split ("\n", 2);
            if (parts.length == 2) app.show_conversation (parts[0], parts[1]);
            return null;
        }

        public override void launch_search (string[] terms, uint32 timestamp) {
            app.activate ();
        }
    }
}
