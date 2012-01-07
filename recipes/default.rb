#
# Cookbook Name:: gitolite
# Recipe:: default
#
# Copyright 2012, Edward Middleton
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#

include_recipe "ssh"

include_recipe "portage::layman"
portage_overlay 'chef-gentoo-bootstrap-overlay'

kw0 = portage_package_keywords "=dev-ruby/grit-2.4.1" do
  action :nothing
end
kw1 = portage_package_keywords "=dev-ruby/hashery-1.4.0" do
  action :nothing
end
kw2 = portage_package_keywords "=dev-ruby/gitolite-0.0.1" do
  action :nothing
end
xs = package "dev-ruby/gitolite" do
  action :nothing
end
kw0.run_action(:create)
kw1.run_action(:create)
kw2.run_action(:create)
xs.run_action(:install)

Gem.clear_paths
require 'gitolite'

package "dev-vcs/gitolite"

user "git" do
  comment "Git User"
  home "/var/lib/gitolite"
  shell "/bin/bash"
end

directory "/var/lib/gitolite" do
  owner "git"
  group "root"
  mode "0755"
end

execute "install gitolite" do
  command <<-CMD
    cp /root/.ssh/id_rsa.pub /var/lib/gitolite/id_rsa.pub
    sudo -Hu git /usr/bin/gl-setup -q /var/lib/gitolite/id_rsa.pub
    git clone git@#{node.fqdn}:gitolite-admin.git /root/gitolite-admin
  CMD
end

ruby_block "create repos and keys" do
  block do
    key_type, key, email =* File.read("/root/.ssh/id_rsa.pub").split
    keys = [{:type => key_type, :key => key, :email => email}]
    repos = { "gitolite-admin" => [ { :type => 'RW+', :users => ['root'] } ] }
    repos_result = search(:repos,"host:#{node.fqdn}")
    if repos_result.last > 0
      filtered_repos = repos_result.first.map{|a|a.to_hash}
      repos.merge(filtered_repos.inject({}){|c,b|c[b['repo']] = b['permissions'];c})
      users = filtered_repos.inject([]){|us,r|us.concat(r['permissions'].first['users']);us}.uniq

      # get users databags for given keys
      users_databags = Chef::Search::Query.new.search(:users, users.map{|u|"name:#{u}"}.join(" OR "))
      
      # get keys for users
      keys.concat(
        users_databags.first.map{|a|a.to_hash["authorized_keys"]}.flatten.map do |k|
          type,key,email =*k.split
          {:type=>type,:key=>key,:email=>email}
        end.reject{|k|k[:type] != 'ssh-rsa' or not k[:email] =~ /.+@.+/}
      )
    end
    ga_repo = Gitolite::GitoliteAdmin.new("/root/gitolite-admin")
    conf = ga_repo.config
    repos.each do |repo_name,permissions|
      repo = nil
      if conf.has_repo? repo_name
        repo = conf.get_repo(repo_name)
      else
        repo = Gitolite::Config::Repo.new(repo_name)
        conf.add_repo(repo)
      end
      permissions.each do |permission|
        repo.add_permission(permission[:type],permission[:refex].to_s, permission[:users])
      end
    end
    keys.each do |user, public_key|
      ga_repo.add_key(Gitolite::SSHKey.new(public_key[:type],public_key[:key],public_key[:email]))
    end
    ga_repo.save_and_apply
  end
end

