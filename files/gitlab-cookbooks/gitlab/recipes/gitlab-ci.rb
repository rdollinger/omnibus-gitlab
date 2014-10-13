#
# Copyright:: Copyright (c) 2012 Opscode, Inc.
# Copyright:: Copyright (c) 2014 GitLab B.V.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

gitlab_ci_source_dir = "/opt/gitlab/embedded/service/gitlab-ci"
gitlab_ci_dir = node['gitlab']['gitlab-ci']['dir']
gitlab_ci_home_dir = File.join(gitlab_ci_dir, "home")
gitlab_ci_etc_dir = File.join(gitlab_ci_dir, "etc")
gitlab_ci_env_dir = "/opt/gitlab/etc/gitlab-ci/env"
gitlab_ci_working_dir = File.join(gitlab_ci_dir, "working")
gitlab_ci_tmp_dir = File.join(gitlab_ci_dir, "tmp")
gitlab_ci_log_dir = node['gitlab']['gitlab-ci']['log_directory']

gitlab_ci_user = node['gitlab']['gitlab-ci']['username']

[
  gitlab_ci_etc_dir,
  gitlab_ci_home_dir,
  gitlab_ci_working_dir,
  gitlab_ci_tmp_dir,
  gitlab_ci_log_dir
].compact.each do |dir_name|
  directory dir_name do
    owner gitlab_ci_user
    mode '0700'
    recursive true
  end
end

directory gitlab_ci_dir do
  owner gitlab_ci_user
  mode '0755'
  recursive true
end

directory gitlab_ci_env_dir do
  owner 'root' # Do not allow the git user to change its own env variables
  group gitlab_ci_user
  mode '0750'
  recursive true
end

group gitlab_ci_user do
  gid node['gitlab']['gitlab-ci']['gid']
end

user gitlab_ci_user do
  uid node['gitlab']['gitlab-ci']['uid']
  gid gitlab_ci_user
  system true
  shell node['gitlab']['gitlab-ci']['shell']
  home gitlab_ci_home_dir
end

template "/opt/gitlab/etc/gitlab-ci/gitlab-ci-rc"

dependent_services = []
dependent_services << "service[unicorn]" if OmnibusHelper.should_notify?("unicorn")
dependent_services << "service[sidekiq]" if OmnibusHelper.should_notify?("sidekiq")

redis_not_listening = OmnibusHelper.not_listening?("redis")
postgresql_not_listening = OmnibusHelper.not_listening?("postgresql")

template_symlink File.join(gitlab_ci_etc_dir, "secret") do
  link_from File.join(gitlab_ci_source_dir, ".secret")
  source "secret_token.erb"
  owner "root"
  group "root"
  mode "0644"
  variables(node['gitlab']['gitlab-ci'].to_hash)
  restarts dependent_services
end

database_attributes = node['gitlab']['gitlab-ci'].to_hash
if node['gitlab']['postgresql']['enable']
  database_attributes.merge!(
    :db_adapter => "postgresql",
    :db_username => node['gitlab']['postgresql']['sql_user'],
    :db_password => node['gitlab']['postgresql']['sql_password'],
    :db_host => node['gitlab']['postgresql']['listen_address'],
    :db_port => node['gitlab']['postgresql']['port']
  )
end

template_symlink File.join(gitlab_ci_etc_dir, "database.yml") do
  link_from File.join(gitlab_ci_source_dir, "config/database.yml")
  source "database.yml.erb"
  owner "root"
  group "root"
  mode "0644"
  variables database_attributes
  helpers SingleQuoteHelper
  restarts dependent_services
end

if node['gitlab']['gitlab-ci']['redis_port']
  redis_url = "redis://#{node['gitlab']['gitlab-ci']['redis_host']}:#{node['gitlab']['gitlab-ci']['redis_port']}"
else
  redis_url = "unix:#{node['gitlab']['gitlab-ci']['redis_socket']}"
end

template_symlink File.join(gitlab_ci_etc_dir, "resque.yml") do
  link_from File.join(gitlab_ci_source_dir, "config/resque.yml")
  source "resque.yml.erb"
  owner "root"
  group "root"
  mode "0644"
  variables(:redis_url => redis_url)
  restarts dependent_services
end

template_symlink File.join(gitlab_ci_etc_dir, "smtp_settings.rb") do
  link_from File.join(gitlab_ci_source_dir, "config/initializers/smtp_settings.rb")
  owner "root"
  group "root"
  mode "0644"
  variables(node['gitlab']['gitlab-ci'].to_hash)
  restarts dependent_services

  unless node['gitlab']['gitlab-ci']['smtp_enable']
    action :delete
  end
end

template_symlink File.join(gitlab_ci_etc_dir, "application.yml") do
  link_from File.join(gitlab_ci_source_dir, "config/application.yml")
  source "application.yml.erb"
  helpers SingleQuoteHelper
  owner "root"
  group "root"
  mode "0644"
  variables(node['gitlab']['gitlab-ci'].to_hash)
  restarts dependent_services
  unless redis_not_listening
    notifies :run, 'execute[clear the gitlab-ci cache]'
  end
end

env_vars = {
  'HOME' => gitlab_ci_home_dir,
  'RAILS_ENV' => node['gitlab']['gitlab-ci']['environment'],
}.merge(node['gitlab']['gitlab-ci']['env'])

env_vars.each do |key, value|
  file File.join(gitlab_ci_env_dir, key) do
    owner gitlab_ci_user
    mode "0600"
    content value
    dependent_services.each do |svc|
      notifies :restart, svc
    end
  end
end

if File.directory?(gitlab_ci_env_dir)
  deleted_env_vars = Dir.entries(gitlab_ci_env_dir) - env_vars.keys - %w{. ..}
  deleted_env_vars.each do |deleted_var|
    file File.join(gitlab_ci_env_dir, deleted_var) do
      action :delete
      dependent_services.each do |svc|
        notifies :restart, svc
      end
    end
  end
end

# replace empty directories in the Git repo with symlinks to /var/opt/gitlab
{
  "/opt/gitlab/embedded/service/gitlab-ci/tmp" => gitlab_ci_tmp_dir,
  "/opt/gitlab/embedded/service/gitlab-ci/log" => gitlab_ci_log_dir
}.each do |link_dir, target_dir|
  link link_dir do
    to target_dir
  end
end

# Make schema.rb writable for when we run `rake db:migrate`
file "/opt/gitlab/embedded/service/gitlab-ci/db/schema.rb" do
  owner gitlab_ci_user
end

# Only run `rake db:migrate` when the gitlab-ci version has changed
remote_file File.join(gitlab_ci_dir, 'VERSION') do
  source "file:///opt/gitlab/embedded/service/gitlab-ci/VERSION"
  notifies :run, 'bash[migrate gitlab-ci database]' unless postgresql_not_listening
  notifies :run, 'execute[clear the gitlab-ci cache]' unless redis_not_listening
  dependent_services.each do |sv|
    notifies :restart, sv
  end
end

execute "clear the gitlab-ci cache" do
  command "/opt/gitlab/bin/gitlab-ci-rake cache:clear"
  action :nothing
end
