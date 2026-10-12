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

## License

GPL-3.0-only - see [LICENSE](LICENSE).
