using Singularity.Messaging;
using Singularity.Apps.Messages;

void check (bool ok, string label) {
    if (!ok) {
        stderr.printf ("FAILED: %s\n", label);
        assert_not_reached ();
    }
}

class FakeChannel : Channel {
    public Gee.ArrayList<Conversation> convs = new Gee.ArrayList<Conversation> ();
    public Gee.HashMap<string, Gee.ArrayList<Message>> logs = new Gee.HashMap<string, Gee.ArrayList<Message>> ();
    public bool offline = false;
    public int sent = 0;

    public FakeChannel () {
        Object (id: "fake:1", provider_id: "fake");
        title = "Fake";
        self_id = "me";
        features = Features.REPLIES | Features.EDIT | Features.READ_MARKERS;
    }

    public Message add (string conv, string id, string author, string text, int64 time) {
        var m = new Message ();
        m.id = id;
        m.conversation = conv;
        m.author_id = author;
        m.author_name = author;
        m.text = text;
        m.time = time;
        m.outgoing = author == "me";
        if (!logs.has_key (conv)) logs[conv] = new Gee.ArrayList<Message> ();
        logs[conv].add (m);
        return m;
    }

    public string failing = "";

    public override async Gee.List<Conversation> conversations (Cancellable? cancel = null) throws Error {
        if (failing != "") throw new MessagingError.NETWORK (failing);
        return convs;
    }

    public override async Gee.List<Message> messages (string conversation, string? after, int limit, Cancellable? cancel = null) throws Error {
        var list = new Gee.ArrayList<Message> ();
        bool take = after == null;
        foreach (var m in logs[conversation] ?? new Gee.ArrayList<Message> ()) {
            if (take) list.add (m);
            else if (m.id == after) take = true;
        }
        return list;
    }

    public override async Message send (string conversation, string text, string? reply_to, Cancellable? cancel = null) throws Error {
        if (offline) throw new MessagingError.NETWORK ("offline");
        sent++;
        return add (conversation, "s%d".printf (sent), "me", text, get_real_time () / 1000000);
    }
}

class FakeProvider : Object, Provider {
    public FakeChannel channel = new FakeChannel ();
    public string id { owned get { return "fake"; } }
    public string name { owned get { return "Fake"; } }
    public string icon_name { owned get { return "x"; } }

    public async Gee.List<Channel> discover () throws Error {
        var list = new Gee.ArrayList<Channel> ();
        list.add (channel);
        return list;
    }
}

void spin (int ms) {
    var loop = new MainLoop ();
    Timeout.add (ms, () => {
        loop.quit ();
        return Source.REMOVE;
    });
    loop.run ();
}

string temp_dir () {
    string base_dir = Environment.get_variable ("MESSAGES_TEST_DIR") ?? Environment.get_tmp_dir ();
    string dir = Path.build_filename (base_dir, "messages-test-%s".printf (Uuid.string_random ()));
    DirUtils.create_with_parents (dir, 0700);
    return dir;
}

void test_merge_and_store () {
    string dir = temp_dir ();
    Environment.set_variable ("SINGULARITY_MESSAGES_DIR", dir, true);
    var engine = new Engine (new Store ());
    var p = new FakeProvider ();
    var c = new Conversation ();
    c.id = "c1";
    c.title = "Bruno";
    c.activity = 100;
    p.channel.convs.add (c);
    p.channel.add ("c1", "1", "bruno", "ciao", 100);
    p.channel.add ("c1", "2", "me", "ehi", 110);
    engine.add_provider (p);
    engine.discover.begin ();
    spin (100);
    check (engine.get_channels ().size == 1, "channel discovered");
    check (engine.entries ().size == 1, "conversation listed");
    engine.load.begin (p.channel, "c1");
    spin (50);
    var msgs = engine.messages ("fake:1", "c1");
    check (msgs.size == 2, "two messages loaded");
    check (engine.find_conversation ("fake:1", "c1").last_preview == "ehi", "preview from last message");
    var again = new Gee.ArrayList<Message> ();
    var dup = new Message ();
    dup.id = "1";
    dup.text = "ciao (edited)";
    dup.time = 100;
    dup.edited = true;
    again.add (dup);
    engine.merge (p.channel, "c1", again, false);
    check (msgs.size == 2 && msgs[0].text == "ciao (edited)", "merge replaces by id");
    engine.flush ();
    var reloaded = new Store ().load_messages ("fake:1", "c1");
    check (reloaded.size == 2 && reloaded[1].text == "ehi" && reloaded[0].edited, "store roundtrip");

    int changes = 0;
    engine.messages_changed.connect (() => changes++);
    var same = new Gee.ArrayList<Message> ();
    foreach (var m in msgs) {
        var copy = new Message ();
        copy.id = m.id;
        copy.conversation = m.conversation;
        copy.author_id = m.author_id;
        copy.author_name = m.author_name;
        copy.text = m.text;
        copy.time = m.time;
        copy.outgoing = m.outgoing;
        copy.edited = m.edited;
        same.add (copy);
    }
    engine.merge (p.channel, "c1", same, false);
    check (changes == 0, "an unchanged poll does not report a change");
    var edited = new Message ();
    edited.id = same[1].id;
    edited.conversation = same[1].conversation;
    edited.author_id = same[1].author_id;
    edited.author_name = same[1].author_name;
    edited.text = "ehi!";
    edited.time = same[1].time;
    edited.outgoing = same[1].outgoing;
    var batch = new Gee.ArrayList<Message> ();
    batch.add (edited);
    engine.merge (p.channel, "c1", batch, false);
    check (changes == 1 && msgs[1].text == "ehi!", "a changed message is reported once");

    int listed = 0;
    engine.conversations_changed.connect (() => listed++);
    engine.refresh.begin (p.channel);
    spin (50);
    check (listed == 0, "an unchanged conversation list does not report a change");
}

uint32 pixel_at (Gdk.Texture t, int x, int y) {
    var px = new uint8[t.get_width () * t.get_height () * 4];
    t.download (px, t.get_width () * 4);
    int o = (y * t.get_width () + x) * 4;
    return ((uint32) px[o + 2] << 16) | ((uint32) px[o + 1] << 8) | px[o];
}

Gdk.Texture solid (int w, int h, uint8 r, uint8 g, uint8 b) {
    var px = new uint8[w * h * 4];
    for (int i = 0; i < w * h; i++) {
        px[i * 4] = b;
        px[i * 4 + 1] = g;
        px[i * 4 + 2] = r;
        px[i * 4 + 3] = 255;
    }
    return new Gdk.MemoryTexture (w, h, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, new Bytes (px), w * 4);
}

void test_group_avatar () {
    string dir = temp_dir ();
    string a = Path.build_filename (dir, "a.png");
    string b = Path.build_filename (dir, "b.png");
    string out_path = Path.build_filename (dir, "group.png");
    try {
        check (solid (120, 80, 255, 0, 0).save_to_png (a), "first fixture written");
        check (solid (64, 64, 0, 0, 255).save_to_png (b), "second fixture written");
        GroupAvatar.compose ({ a, b }, out_path);
        var got = Gdk.Texture.from_filename (out_path);
        check (got.get_width () == 96 && got.get_height () == 96, "group avatar is square");
        check (pixel_at (got, 10, 48) == 0xff0000, "left half shows the first member");
        check (pixel_at (got, 85, 48) == 0x0000ff, "right half shows the second member");
    } catch (Error e) {
        check (false, "group avatar: " + e.message);
    }
}

void test_send_pending_and_retry () {
    string dir = temp_dir ();
    Environment.set_variable ("SINGULARITY_MESSAGES_DIR", dir, true);
    var engine = new Engine (new Store ());
    var p = new FakeProvider ();
    var c = new Conversation ();
    c.id = "c1";
    c.title = "Bruno";
    p.channel.convs.add (c);
    engine.add_provider (p);
    engine.discover.begin ();
    spin (50);
    p.channel.offline = true;
    engine.send.begin (p.channel, "c1", "first", null);
    spin (50);
    var msgs = engine.messages ("fake:1", "c1");
    check (msgs.size == 1 && msgs[0].state == MessageState.FAILED, "offline send marked failed");
    engine.flush ();
    var stored = new Store ().load_messages ("fake:1", "c1");
    check (stored.size == 1 && stored[0].state == MessageState.FAILED, "failed message kept in outbox");
    p.channel.offline = false;
    engine.retry (p.channel, "c1", msgs[0]);
    spin (50);
    check (msgs.size == 1 && msgs[0].state == MessageState.SENT && msgs[0].id == "s1", "retry replaced pending with sent");
    engine.send.begin (p.channel, "c1", "second", "s1");
    spin (50);
    check (msgs.size == 2 && msgs[1].id == "s2", "second message sent");
    engine.merge (p.channel, "c1", p.channel.logs["c1"], false);
    check (msgs.size == 2, "echo of sent messages does not duplicate");
    var local = new Message ();
    local.id = "local-1";
    local.text = "sms";
    local.outgoing = true;
    local.time = get_real_time () / 1000000;
    var batch = new Gee.ArrayList<Message> ();
    batch.add (local);
    engine.merge (p.channel, "c1", batch, false);
    var phone = new Gee.ArrayList<Message> ();
    phone.add (p.channel.add ("c1", "99", "me", "sms", local.time + 2));
    engine.merge (p.channel, "c1", phone, false);
    int copies = 0;
    foreach (var m in msgs) if (m.text == "sms") copies++;
    check (copies == 1 && msgs[msgs.size - 1].id == "99", "local copy replaced by the stored one");
}

void test_notifications_only_for_new_incoming () {
    string dir = temp_dir ();
    Environment.set_variable ("SINGULARITY_MESSAGES_DIR", dir, true);
    var engine = new Engine (new Store ());
    var p = new FakeProvider ();
    var c = new Conversation ();
    c.id = "c1";
    c.title = "Bruno";
    p.channel.convs.add (c);
    engine.add_provider (p);
    engine.discover.begin ();
    spin (50);
    int arrived = 0;
    engine.arrived.connect (() => arrived++);
    int64 now = get_real_time () / 1000000;
    var batch = new Gee.ArrayList<Message> ();
    batch.add (p.channel.add ("c1", "1", "bruno", "old", now - 3600));
    batch.add (p.channel.add ("c1", "2", "bruno", "new", now));
    batch.add (p.channel.add ("c1", "3", "me", "mine", now));
    engine.merge (p.channel, "c1", batch, true);
    check (arrived == 1, "only the fresh incoming message notifies");
    engine.focus ("fake:1", "c1", true);
    var more = new Gee.ArrayList<Message> ();
    more.add (p.channel.add ("c1", "4", "bruno", "seen", now));
    engine.merge (p.channel, "c1", more, true);
    check (arrived == 1, "focused visible conversation does not notify");
}

void test_repeated_poll_error_reported_once () {
    string dir = temp_dir ();
    Environment.set_variable ("SINGULARITY_MESSAGES_DIR", dir, true);
    var engine = new Engine (new Store ());
    var p = new FakeProvider ();
    engine.add_provider (p);
    engine.discover.begin ();
    spin (50);
    int reports = 0;
    engine.problem.connect (() => reports++);
    p.channel.failing = "no registration";
    for (int i = 0; i < 3; i++) {
        engine.refresh.begin (p.channel);
        spin (20);
    }
    check (reports == 1, "the same poll error is reported once");
    check (p.channel.attention == "!no registration", "the channel keeps the error");
    p.channel.failing = "";
    engine.refresh.begin (p.channel);
    spin (20);
    check (p.channel.attention == "", "recovery clears the error");
    p.channel.failing = "no registration";
    engine.refresh.begin (p.channel);
    spin (20);
    check (reports == 2, "the error is reported again after a recovery");
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/messages/merge-store", test_merge_and_store);
    Test.add_func ("/messages/group-avatar", test_group_avatar);
    Test.add_func ("/messages/send-retry", test_send_pending_and_retry);
    Test.add_func ("/messages/notify", test_notifications_only_for_new_incoming);
    Test.add_func ("/messages/poll-error-once", test_repeated_poll_error_reported_once);
    return Test.run ();
}
