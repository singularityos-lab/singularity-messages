project('singularity-messages', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-messages"', language: 'c')
subdir('po')

gtk_dep    = dependency('gtk4')
gee_dep    = dependency('gee-0.8')
gio_dep    = dependency('gio-2.0')
soup_dep   = dependency('libsoup-3.0')
json_dep   = dependency('json-glib-1.0')
peas_dep   = dependency('libpeas-2')

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

core = files(
  'src/store.vala',
  'src/engine.vala',
  'src/providers/rest.vala',
  'src/providers/talk.vala',
  'src/providers/google_chat.vala',
  'src/providers/teams.vala',
  'src/providers/sms.vala',
  'src/providers/nearby.vala',
  'src/providers/socket.vala',
  'src/providers/groups.vala',
)

deps = [gtk_dep, gee_dep, gio_dep, soup_dep, json_dep, peas_dep, libsingularity_dep]

executable('singularity-messages',
  core + files(
    'src/notifier.vala',
    'src/widgets.vala',
    'src/composer.vala',
    'src/new_conversation.vala',
    'src/new_group.vala',
    'src/search.vala',
    'src/window.vala',
    'src/app.vala',
  ),
  dependencies: deps,
  install: true
)

engine_test = executable('engine-test', core + files('tests/engine_test.vala'), dependencies: deps)
test('engine', engine_test, env: ['GSETTINGS_BACKEND=memory', 'MESSAGES_TEST_DIR=' + meson.current_build_dir()])

shared_module('messages-echo',
  files('examples/echo/echo_provider.vala'),
  dependencies: deps,
  install: false
)
configure_file(input: 'examples/echo/echo.plugin', output: 'echo.plugin', copy: true)

service_conf = configuration_data()
service_conf.set('bindir', get_option('prefix') / get_option('bindir'))
configure_file(
  input: 'data/dev.sinty.messages.service.in',
  output: 'dev.sinty.messages.service',
  configuration: service_conf,
  install: true,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)

install_data('data/dev.sinty.messages.desktop',
  install_dir: get_option('datadir') / 'applications'
)

install_data('data/capabilities/dev.sinty.Messages1.ini', 'data/capabilities/dev.sinty.Collab.Message1.ini',
  install_dir: get_option('datadir') / 'singularity' / 'capabilities'
)

install_data('data/dev.sinty.messages.search.ini',
  install_dir: get_option('datadir') / 'singularity' / 'search-providers'
)

install_data('data/share-targets/dev.sinty.messages.send.ini',
  install_dir: get_option('datadir') / 'singularity' / 'share-targets'
)

install_data('data/icons/dev.sinty.messages.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)
