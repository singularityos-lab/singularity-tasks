project('singularity-tasks', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-tasks"', language: 'c')
subdir('po')

gtk_dep  = dependency('gtk4')
gee_dep  = dependency('gee-0.8')
gio_dep  = dependency('gio-2.0')
json_dep = dependency('json-glib-1.0')
math_dep = meson.get_compiler('c').find_library('m', required: false)
posix_dep = meson.get_compiler('vala').find_library('posix')

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

gnome = import('gnome')
resources = gnome.compile_resources(
  'singularity-tasks-resources',
  'resources/dev.sinty.tasks.gresource.xml',
  source_dir: meson.current_source_dir() / 'data' / 'icons',
)

core_sources = files(
  'src/model.vala',
  'src/storage.vala',
  'src/ical.vala',
  'src/format.vala',
  'src/quickparse.vala',
  'src/repeat.vala',
  'src/focus.vala',
  'src/calendar_feed.vala',
  'src/transfer_metadata.vala',
)

executable('singularity-tasks',
  core_sources + files(
    'src/row.vala',
    'src/detail.vala',
    'src/window.vala',
    'src/app.vala',
    'src/search.vala',
    'src/online.vala',
    'src/list_transfer.vala',
  ) + [resources],
  dependencies: [gtk_dep, gee_dep, gio_dep, json_dep, math_dep, libsingularity_dep],
  install: true
)

shared_module('singularity-tasks-widget',
  core_sources + files('src/online_mirror.vala', 'widget/today_widget.vala'),
  dependencies: [gtk_dep, gee_dep, gio_dep, json_dep, math_dep, libsingularity_dep],
  install: true,
  install_dir: get_option('libdir') / 'singularity' / 'widgets'
)
install_data('widget/dev.sinty.tasks.today.widget',
  install_dir: get_option('datadir') / 'singularity' / 'widgets'
)

shared_module('tasks-badge',
  files('plugin/tasks_badge.vala'),
  dependencies: [gtk_dep, gee_dep, gio_dep, json_dep, libsingularity_dep, dependency('libpeas-2')],
  install: true,
  install_dir: get_option('libdir') / 'singularity' / 'plugins' / 'tasks-badge'
)
install_data('plugin/tasks-badge.plugin',
  install_dir: get_option('libdir') / 'singularity' / 'plugins' / 'tasks-badge'
)

install_data('data/search-providers/dev.sinty.tasks.ini',
  install_dir: get_option('datadir') / 'singularity' / 'search-providers'
)

service_conf = configuration_data()
service_conf.set('bindir', get_option('prefix') / get_option('bindir'))
configure_file(
  input: 'data/dev.sinty.tasks.service.in',
  output: 'dev.sinty.tasks.service',
  configuration: service_conf,
  install: true,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)

tasks_test = executable('tasks-test',
  core_sources + files('tests/tasks_test.vala'),
  dependencies: [gee_dep, gio_dep, json_dep, math_dep, posix_dep],
)
test('tasks', tasks_test, env: ['TASKS_FIXTURES=' + meson.current_source_dir() / 'tests' / 'fixtures', 'TZ=Europe/Rome'])

executable('tasks-transfer-test',
  core_sources + files('src/online.vala', 'src/list_transfer.vala', 'tests/transfer_test.vala'),
  dependencies: [gtk_dep, gee_dep, gio_dep, json_dep, math_dep, libsingularity_dep],
)

install_data('data/dev.sinty.tasks.desktop',
  install_dir: get_option('datadir') / 'applications'
)

install_data('data/dev.sinty.tasks.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)

install_data('data/dev.sinty.tasks.json',
  install_dir: get_option('datadir') / 'singularity' / 'app-settings'
)

install_data('data/icons/dev.sinty.tasks.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)

install_data('data/share-targets/dev.sinty.tasks.add.ini',
  install_dir: get_option('datadir') / 'singularity' / 'share-targets'
)
