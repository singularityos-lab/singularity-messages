# Echo, a sample chat service for Messages

Messages loads chat services as plugins. A service is a class that implements
`Singularity.Messaging.Provider`; each account it finds is a
`Singularity.Messaging.Channel`, which lists conversations, returns messages
and sends new ones. Messages does the rest: the window, the local archive,
the outbox, notifications with quick reply, the dock badge and search.

This plugin answers every message you send, which is enough to see every part
of the contract working.

## Build and install

```sh
meson setup build --prefix ~/.local
meson install -C build
```

The plugin lands in `~/.local/lib/singularity/app-plugins/messages/echo`.
Turn it on in Settings, Apps, Messages, and an "Echo" account appears.

## Writing your own service

1. Implement `Provider.discover ()`: return one `Channel` for each account the
   user has. Services that use an online account added in Settings read it
   from `Singularity.Accounts.Manager`, and ask it for credentials, so your
   plugin never stores passwords or tokens.
2. Implement the three required `Channel` methods: `conversations`,
   `messages` and `send`.
3. Declare what else the service can do with `features` and override the
   matching methods: attachments (`upload`, `download`), replies, editing,
   deleting, reactions, read markers (`mark_read`) and new conversations
   (`start`, `search_people`).
4. Say how news arrive with `realtime`: `POLL` (Messages asks every
   `poll_seconds`), `LONG_POLL` (override `wait`, which returns when the open
   conversation has news) or `PUSH` (emit `incoming` and
   `conversations_changed` yourself).
5. Add a `.plugin` file with `X-Singularity-Host=dev.sinty.messages`.
