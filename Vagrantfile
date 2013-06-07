# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant::Config.run do |config|
  config.vm.box = "wheezy64"
  config.vm.box_url = "http://labs.enovance.com/pub/wheezy.box"

  config.vm.provision :shell, :path => "provision.sh"
end
