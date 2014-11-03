define django::deploy(
  $app_name = $title,
  $venv_path,
  $clone_path,
  $git_url,
  $user,
  $gunicorn_app_module,
  $project_path = undef,
  $requirements = "requirements.txt",
  $settings_local = undef,
  $settings_local_source = undef,
  $migrate = false,
  $collectstatic = false,
  $fixtures = false,
  $bind = "0.0.0.0:8000",
  $backlog = undef,
  $workers = "multiprocessing.cpu_count() * 2 + 1",
  $worker_class = undef,
  $worker_connections = undef,
  $max_requests = undef,
  $timeout = undef,
  $timeout_app = 30,
  $graceful_timeout = undef,
  $keepalive = undef,
  $limit_request_line = undef,
  $limit_request_fields = undef,
  $numprocs = undef,
  $log_file = "/tmp/gunicorn.log",
  $newrelic = undef,
  $environment = undef,
  $virtualenv_system_package = undef,
) {

  # Set django absolute path
  if $project_path {
    $project_abs_path = "${clone_path}/${project_path}"
  } else {
    $project_abs_path = $clone_path
  }

  # Clone APP
  exec { "git-clone ${app_name}":
    command => "git clone ${git_url} ${clone_path}",
    user    => $user,
    path    => ['/usr/bin'],
    unless  => "test -d ${clone_path}/.git",
    require => Package['git'],
    timeout => 0,
  }

  # Create virtualenv
  <% if @virtualenv_system_package %>
  virtualenv::create { $venv_path:
    user            => $user,
    requirements    => "${clone_path}/${requirements}",
    system_packages => true,
    require         => Exec["git-clone ${app_name}"],
    before          => File["gunicorn ${app_name}"]
  }
  <% else %>
  virtualenv::create { $venv_path:
    user            => $user,
    requirements    => "${clone_path}/${requirements}",
    require         => Exec["git-clone ${app_name}"],
    before          => File["gunicorn ${app_name}"]
  }
  <% end %>

  # Create settings local file
  if $settings_local_source {
    file { "settings_local ${app_name}":
      ensure  => present,
      path    => "${project_abs_path}/${settings_local}",
      source  => $settings_local_source,
      owner   => $user,
      require => Exec["git-clone ${app_name}"],
      notify  => Exec["syncdb ${app_name}"],
    }
    $migrate_and_collectstatic_require = [Exec["syncdb ${app_name}"], File["settings_local ${app_name}"]]
  } else {
    $migrate_and_collectstatic_require = Exec["syncdb ${app_name}"]
  }

  # Run syncdb
  exec { "syncdb ${app_name}":
    command     => 'python manage.py syncdb --noinput',
    path        => "${venv_path}/bin/",
    cwd         => $project_abs_path,
    user        => $user,
    require     => Virtualenv::Create["${venv_path}"],
    subscribe   => Exec["git-clone ${app_name}"],
    refreshonly => true,
    timeout     => 0,
  }
  
  # Run collectstatic
  if ($collectstatic) {
    exec { "collectstatic ${app_name}":
      command     => 'python manage.py collectstatic --noinput',
      path        => "${venv_path}/bin/",
      cwd         => $project_abs_path,
      user        => $user,
      require     => $migrate_and_collectstatic_require,
      before      => Supervisor::App[$app_name],
      subscribe   => Exec["git-clone ${app_name}"],
      refreshonly => true,
      timeout     => 0,
    }
  }
  # Run migrate
  if ($migrate) {
    exec { "migrate ${app_name}":
      command     => 'python manage.py migrate --noinput',
      path        => "${venv_path}/bin/",
      cwd         => $project_abs_path,
      user        => $user,
      require     => $migrate_and_collectstatic_require,
      before      => Supervisor::App[$app_name],
      subscribe   => Exec["git-clone ${app_name}"],
      refreshonly => true,
      timeout     => 0,
    }
  }
  # Install fixtures
  if ($fixtures) {
    exec { "fixtures ${app_name}":
      command     => "python manage.py loaddata ${fixtures}",
      path        => "${venv_path}/bin/",
      cwd         => $project_abs_path,
      user        => $user,
      before      => Supervisor::App[$app_name],
      subscribe   => [Exec["collectstatic ${app_name}"], Exec["syncdb ${app_name}"]],
      refreshonly => true,
      timeout     => 0,
    }
  }
  # Create gunicorn conf file
  file { "gunicorn ${app_name}":
    path    => "${venv_path}/gunicorn.conf.py",
    ensure  => present,
    content => template("django/gunicorn.conf.py.erb"),
    owner   => $user,
    notify  => Service["supervisor_${app_name}"]
  }

  # Configure supervisor to run django
  if ($numprocs) {
    if ($newrelic) {
       supervisor::app { $app_name:
        command       => "${venv_path}/bin/newrelic-admin run-program ${venv_path}/bin/gunicorn_django -b ${bind}%(process_num)s -c ${venv_path}/gunicorn.conf.py --log-file ${log_file}",
        numprocs      => $numprocs,
        directory     => $project_abs_path,
        process_name  => "${app_name}-%(process_num)s",
        user          => $user,
        environment   => $environment,
        require       => File["gunicorn ${app_name}"],
      }
    } else {
        supervisor::app { $app_name:
        command       => "${venv_path}/bin/gunicorn_django -b ${bind}%(process_num)s -c ${venv_path}/gunicorn.conf.py --log-file ${log_file}",
        numprocs      => $numprocs,
        directory     => $project_abs_path,
        process_name  => "${app_name}-%(process_num)s",
        user          => $user,
        environment   => $environment,
        require       => File["gunicorn ${app_name}"],
      }   
    }
  } else {
    if ($newrelic) {
      supervisor::app { $app_name:
        command      => "${venv_path}/bin/newrelic-admin run-program ${venv_path}/bin/gunicorn ${gunicorn_app_module} -c ${venv_path}/gunicorn.conf.py",
        directory    => $project_abs_path,
        user         => $user,
        environment  => $environment,
        require   => File["gunicorn ${app_name}"],
      }
    } else {
      supervisor::app { $app_name:
        command      => "${venv_path}/bin/gunicorn ${gunicorn_app_module} -c ${venv_path}/gunicorn.conf.py",
        directory    => $project_abs_path,
        user         => $user,
        environment  => $environment,
        require   => File["gunicorn ${app_name}"],
      }

    }
  }

}
