#
## Copyright:: Copyright (c) 2014 GitLab.com
## License:: Apache License, Version 2.0
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
## http://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##
#
account_helper = AccountHelper.new(node)

git_user = account_helper.gitlab_user
git_group = account_helper.gitlab_group
gitlab_shell_dir = "/opt/gitlab/embedded/service/gitlab-shell"
gitlab_shell_var_dir = node['gitlab']['gitlab-shell']['dir']
git_data_directories = node['gitlab']['gitlab-shell']['git_data_directories']
repositories_storages = node['gitlab']['gitlab-rails']['repositories_storages']
ssh_dir = File.join(node['gitlab']['user']['home'], ".ssh")
authorized_keys = node['gitlab']['gitlab-shell']['auth_file']
log_directory = node['gitlab']['gitlab-shell']['log_directory']
hooks_directory = node['gitlab']['gitlab-rails']['gitlab_shell_hooks_path']
gitlab_shell_keys_check = File.join(gitlab_shell_dir, 'bin/gitlab-keys')

# Holds git-data, by default one shard at /var/opt/gitlab/git-data
# Can be changed by user using git_data_dirs option
git_data_directories.each do |_name, git_data_directory|
  storage_directory git_data_directory['path'] do
    owner git_user
    mode "0700"
  end
end

# Holds git repositories, by default at /var/opt/gitlab/git-data/repositories
# Should not be changed by user. Different permissions to git_data_dir set.
repositories_storages.each do |_name, repositories_storage|
  storage_directory repositories_storage['path'] do
    owner git_user
    mode "2770"
  end
end

# Creates `.ssh` directory to hold authorized_keys
[
  ssh_dir,
  File.dirname(authorized_keys)
].uniq.each do |dir|
  storage_directory dir do
    owner git_user
    group git_group
    mode "0700"
  end
end

[
  log_directory,
  gitlab_shell_var_dir
].each do |dir|
  directory dir do
    owner git_user
    mode "0700"
    recursive true
  end
end

# If no internal_api_url is specified, default to the IP/port Unicorn listens on
api_url = node['gitlab']['gitlab-rails']['internal_api_url']
api_url ||= "http://#{node['gitlab']['unicorn']['listen']}:#{node['gitlab']['unicorn']['port']}#{node['gitlab']['unicorn']['relative_url']}"

redis_port = node['gitlab']['gitlab-rails']['redis_port']
if redis_port
  # Leave out redis socket setting because in gitlab-shell, setting a Redis socket
  # overrides TCP connection settings.
  redis_socket = nil
else
  redis_socket = node['gitlab']['gitlab-rails']['redis_socket']
end

templatesymlink "Create a config.yml and create a symlink to Rails root" do
  link_from File.join(gitlab_shell_dir, "config.yml")
  link_to File.join(gitlab_shell_var_dir, "config.yml")
  source "gitlab-shell-config.yml.erb"
  variables({
    :user => git_user,
    :api_url => api_url,
    :authorized_keys => authorized_keys,
    :redis_host => node['gitlab']['gitlab-rails']['redis_host'],
    :redis_port => redis_port,
    :redis_socket => redis_socket,
    :redis_password => node['gitlab']['gitlab-rails']['redis_password'],
    :redis_database => node['gitlab']['gitlab-rails']['redis_database'],
    :redis_sentinels => node['gitlab']['gitlab-rails']['redis_sentinels'],
    :log_file => File.join(log_directory, "gitlab-shell.log"),
    :log_level => node['gitlab']['gitlab-shell']['log_level'],
    :audit_usernames => node['gitlab']['gitlab-shell']['audit_usernames'],
    :http_settings => node['gitlab']['gitlab-shell']['http_settings'],
    :git_trace_log_file => node['gitlab']['gitlab-shell']['git_trace_log_file'],
    :custom_hooks_dir => node['gitlab']['gitlab-shell']['custom_hooks_dir']
  })
end

link File.join(gitlab_shell_dir, ".gitlab_shell_secret") do
  to "/opt/gitlab/embedded/service/gitlab-rails/.gitlab_shell_secret"
end

execute "#{gitlab_shell_keys_check} check-permissions" do
  user git_user
  group git_group
end

# If SELinux is enabled, make sure that OpenSSH thinks the .ssh directory and authorized_keys file of the
# git_user is valid.
bash "Set proper security context on ssh files for selinux" do
  code <<-EOS
    semanage fcontext -a -t ssh_home_t '#{ssh_dir}(/.*)?'
    semanage fcontext -a -t ssh_home_t '#{authorized_keys}'
    restorecon -R -v '#{ssh_dir}'
    restorecon -v '#{authorized_keys}'
  EOS
  only_if "id -Z"
end
