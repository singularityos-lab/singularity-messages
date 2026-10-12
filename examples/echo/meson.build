project('messages-echo', ['vala', 'c'], version: '0.1.0', meson_version: '>= 0.59.0')

shared_module('messages-echo',
  files('echo_provider.vala'),
  dependencies: [
    dependency('gee-0.8'),
    dependency('gio-2.0'),
    dependency('json-glib-1.0'),
    dependency('libpeas-2'),
    dependency('singularity-1.0'),
  ],
  install: true,
  install_dir: get_option('libdir') / 'singularity' / 'app-plugins' / 'messages' / 'echo'
)

install_data('echo.plugin',
  install_dir: get_option('libdir') / 'singularity' / 'app-plugins' / 'messages' / 'echo'
)
