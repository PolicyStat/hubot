# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-16.04"
  config.vm.provision "shell", inline: <<-SHELL
    echo "deb [trusted=yes]    https://deb.nodesource.com/node xenial main" > /etc/apt/sources.list.d/node.js.list
    apt-get update
    apt-get install -y nodejs npm
    ln -s /vagrant hubot
  SHELL
end
