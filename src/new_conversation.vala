using Gtk;
using Singularity.Messaging;
using Singularity.Widgets;

namespace Singularity.Apps.Messages {

    public class NewConversationDialog : AppDialog {
        private Engine engine;
        private Gee.ArrayList<Channel> choices = new Gee.ArrayList<Channel> ();
        private DropDown service;
        private Gtk.SearchEntry search;
        private ListBox results;
        private Label hint;
        private Cancellable? cancel = null;
        private uint search_id = 0;

        public signal void started (Channel channel, string conversation);

        public NewConversationDialog (Gtk.Application app, Gtk.Window parent, Engine engine, string query = "") {
            base (app, true);
            this.engine = engine;
            transient_for = parent;
            set_title (_("New Conversation"));
            set_default_size (460, 520);

            var names = new Gtk.StringList (null);
            foreach (var ch in engine.get_channels ()) {
                if (!ch.supports (Features.NEW_CONVERSATION)) continue;
                choices.add (ch);
                names.append (ch.title);
            }

            var box = new Box (Orientation.VERTICAL, 12);
            box.margin_start = 18;
            box.margin_end = 18;
            box.margin_bottom = 18;
            box.margin_top = 6;

            var group = new PreferencesGroup (_("Write To"));
            var service_row = new ActionRow (_("Service"), null, "chat-message-new-symbolic");
            service = new DropDown (names, null);
            service.valign = Align.CENTER;
            service_row.add_suffix (service);
            group.add_row (service_row);
            box.append (group);

            search = new Gtk.SearchEntry ();
            search.placeholder_text = _("Name, address or phone number");
            search.text = query;
            box.append (search);

            results = new ListBox ();
            results.add_css_class ("boxed-list");
            results.selection_mode = SelectionMode.NONE;
            results.row_activated.connect ((row) => choose.begin (row.get_data<string> ("peer")));
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = results;
            box.append (scroll);

            hint = new Label ("");
            hint.add_css_class ("dim-label");
            hint.wrap = true;
            hint.xalign = 0;
            box.append (hint);
            content_box.append (box);

            search.search_changed.connect (() => queue_search ());
            search.activate.connect (() => {
                string t = search.text.strip ();
                var first = results.get_row_at_index (0);
                if (first != null) choose.begin (first.get_data<string> ("peer"));
                else if (t != "") choose.begin (t);
            });
            if (Regex.match_simple ("^[+0-9 ()./-]{5,}$", query.strip ())) {
                for (int i = 0; i < choices.size; i++) {
                    if (choices[i].provider_id == "sms") {
                        service.selected = i;
                        break;
                    }
                }
            }
            service.notify["selected"].connect (() => queue_search ());
            if (choices.size == 0) {
                hint.label = _("None of your accounts can start new conversations here.");
                search.sensitive = false;
            }
            queue_search ();
        }

        private Channel? current () {
            uint i = service.selected;
            return i < choices.size ? choices[(int) i] : null;
        }

        private void queue_search () {
            if (search_id != 0) Source.remove (search_id);
            search_id = Timeout.add (250, () => {
                search_id = 0;
                run.begin ();
                return Source.REMOVE;
            });
        }

        private void add_row (string peer, string title, string detail) {
            var row = new ActionRow (title, detail != "" ? detail : null, "avatar-default-symbolic");
            row.activatable = true;
            row.set_data<string> ("peer", peer);
            results.append (row);
        }

        private async void run () {
            var ch = current ();
            if (ch == null) return;
            if (cancel != null) cancel.cancel ();
            cancel = new Cancellable ();
            var mine = cancel;
            Widget? child;
            while ((child = results.get_first_child ()) != null) results.remove (child);
            string q = search.text.strip ();
            if (q != "") add_row (q, _("Write to %s").printf (q), ch.title);
            try {
                var people = yield ch.search_people (q, mine);
                if (mine.is_cancelled ()) return;
                foreach (var p in people) add_row (p.id, p.name, p.detail);
                string note = people.size == 0 && q == "" ? _("Type a name to find people on %s.").printf (ch.title) : "";
                hint.label = note;
            } catch (Error e) {
                if (!mine.is_cancelled ()) hint.label = e.message;
            }
        }

        private async void choose (string? peer) {
            var ch = current ();
            if (ch == null || peer == null || peer == "") return;
            sensitive = false;
            string? id = yield engine.start (ch, peer);
            sensitive = true;
            if (id == null) {
                hint.label = _("Could not start the conversation.");
                return;
            }
            started (ch, id);
            close_dialog ();
        }
    }
}
