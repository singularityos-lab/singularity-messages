# singularity-messages

> [!IMPORTANT]
> Report bugs and request features in the
> [Singularity Desktop tracker](https://github.com/singularityos-lab/singularity-desktop/issues/new/choose).

Messages for the [Singularity Desktop Environment](https://github.com/singularityos-lab): chat on Nextcloud Talk, Google Chat, Teams, SMS from a paired phone and nearby devices in one place.

## Requirements

- [Meson](https://mesonbuild.com/) ≥ 1.0
- [Vala](https://vala.dev/) compiler
- GTK4, libgee-0.8, libsoup-3.0, json-glib, libpeas-2
- [libsingularity](https://github.com/singularityos-lab/libsingularity)

## Build & Install

```sh
meson setup build
meson compile -C build
meson install -C build
```

Providers are plugins. `examples/echo` shows a minimal one.

## Groups

**File > New Group** puts people from different services in one conversation: Nextcloud Talk, Teams or Google Chat contacts, nearby computers and local integrations can all be members of the same group.

The computer that creates the group keeps it and forwards every message to the other members. Nearby computers receive it as a real group, with each author's name. Members on online services receive it in their direct conversation, prefixed with the author's name.

## Local integrations

Messages listens on a Unix socket so that scripts, services and bots can chat like any other contact. Each program that connects shows up under **Local Integrations**, and it can be added to groups.

The socket is `$XDG_RUNTIME_DIR/singularity/messages.sock` (set `SINGULARITY_MESSAGES_SOCKET` to change it). It is only reachable by the same user, and Messages must be running.

The protocol is one JSON object per line, in both directions.

First introduce the program. `id` is a stable identifier (letters, digits, `.`, `-`, `_`), `name` is what people see:

```json
{"type": "hello", "id": "build-bot", "name": "Build Bot"}
```

Messages answers `{"type": "welcome", "conversation": "build-bot"}`. Messages written to the program while it was not connected are delivered right after.

To write in the program's own conversation:

```json
{"type": "message", "text": "Build 1432 passed"}
```

To write in a group the program is a member of, add the group id received with an earlier message:

```json
{"type": "message", "group": "6f0c...", "text": "Deploy started"}
```

Messages sent to the program arrive as:

```json
{"type": "message", "id": "...", "author": "Ada", "text": "status?", "time": 1791980000}
```

with `group` and `group_title` set when they come from a group. `{"type": "ping"}` is answered with `{"type": "pong"}`. Mistakes are answered with `{"type": "error", "message": "..."}`.

A one-shot notification from a shell script:

```sh
printf '%s\n' '{"type":"hello","id":"backup","name":"Backups"}' \
  '{"type":"message","text":"Nightly backup finished"}' |
  socat - UNIX-CONNECT:"$XDG_RUNTIME_DIR/singularity/messages.sock"
```

A bot that answers every message:

```python
import json, os, socket

path = os.path.join(os.environ["XDG_RUNTIME_DIR"], "singularity", "messages.sock")
s = socket.socket(socket.AF_UNIX)
s.connect(path)
f = s.makefile("rw")
f.write(json.dumps({"type": "hello", "id": "echo", "name": "Echo"}) + "\n")
f.flush()
for line in f:
    msg = json.loads(line)
    if msg.get("type") != "message":
        continue
    reply = {"type": "message", "text": "You said: " + msg["text"]}
    if msg.get("group"):
        reply["group"] = msg["group"]
    f.write(json.dumps(reply) + "\n")
    f.flush()
```

## License

GPL-3.0-only - see [LICENSE](LICENSE).
