using Gtk;
using Singularity.Messaging;
using Singularity.Widgets;

namespace Singularity.Apps.Messages {

    public class NewGroupDialog : AppDialog {
        private Engine engine;
        private EntryRow name_row;
        private ListBox people;
        private Label hint;
        private Button create_button;
        private Gee.ArrayList<GroupMember> candidates = new Gee.ArrayList<GroupMember> ();
        private Gee.HashSet<int> chosen = new Gee.HashSet<int> ();

        public signal void started (Channel channel, string conversation);

        public NewGroupDialog (Gtk.Application app, Gtk.Window parent, Engine engine) {
            base (app, true);
            this.engine = engine;
            transient_for = parent;
            set_title (_("New Group"));
            set_default_size (460, 560);

            var box = new Box (Orientation.VERTICAL, 12);
            box.margin_start = 18;
            box.margin_end = 18;
            box.margin_bottom = 18;
            box.margin_top = 6;

            var name_group = new PreferencesGroup (_("Group"));
            name_row = new EntryRow (_("Name"));
            name_group.add_row (name_row);
            box.append (name_group);

            var label = new Label (_("Members"));
            label.add_css_class ("heading");
            label.xalign = 0;
            box.append (label);

            people = new ListBox ();
            people.add_css_class ("boxed-list");
            people.selection_mode = SelectionMode.NONE;
            var scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = people;
            box.append (scroll);

            hint = new Label ("");
            hint.add_css_class ("dim-label");
            hint.wrap = true;
            hint.xalign = 0;
            box.append (hint);

            create_button = new Button.with_label (_("Create Group"));
            create_button.add_css_class ("suggested-action");
            create_button.halign = Align.END;
            create_button.sensitive = false;
            create_button.clicked.connect (create);
            box.append (create_button);
            content_box.append (box);

            collect ();
        }

        private void collect () {
            var known = new Gee.HashSet<string> ();
            foreach (var e in engine.entries ()) {
                if (e.channel.id == "groups:local") continue;
                if (e.conversation.kind != ConversationKind.DIRECT) continue;
                string key = Engine.key_of (e.channel.id, e.conversation.id);
                if (!known.add (key)) continue;
                add_candidate (new GroupMember (e.channel.id, e.conversation.id, e.conversation.title), e.channel.title);
            }
            if (Singularity.Collab.Client.installed ()) {
                foreach (var p in Singularity.Collab.Client.get_default ().people) {
                    string key = Engine.key_of (GroupsChannel.NEARBY, p.id);
                    if (!known.add (key)) continue;
                    add_candidate (new GroupMember (GroupsChannel.NEARBY, p.id, p.name), _("Nearby Computers"));
                }
            }
            if (candidates.size == 0) hint.label = _("Start a conversation first: groups are made of the people and integrations you already write to.");
        }

        private void add_candidate (GroupMember member, string detail) {
            int index = candidates.size;
            candidates.add (member);
            var row = new ActionRow (member.name != "" ? member.name : member.conversation, detail, "avatar-default-symbolic");
            var check = new CheckButton ();
            check.valign = Align.CENTER;
            check.toggled.connect (() => {
                if (check.active) chosen.add (index);
                else chosen.remove (index);
                create_button.sensitive = chosen.size > 0;
            });
            row.add_suffix (check);
            row.activatable = true;
            row.activated.connect (() => check.active = !check.active);
            people.append (row);
        }

        private void create () {
            var groups = GroupsProvider.instance;
            if (groups == null) {
                hint.label = _("Groups are not ready yet, try again in a moment.");
                return;
            }
            var members = new Gee.ArrayList<GroupMember> ();
            foreach (int i in chosen) members.add (candidates[i]);
            var g = groups.create (name_row.text, members);
            started (groups, g.id);
            close_dialog ();
        }
    }
}
