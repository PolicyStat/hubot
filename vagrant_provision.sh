echo "deb [trusted=yes]    https://deb.nodesource.com/node xenial main" | sudo tee /etc/apt/sources.list.d/node.js.list > /dev/null
sudo apt-get update
sudo apt-get install -y nodejs npm
# Needed for hipchat
sudo apt-get install -y libexpat1-dev
sudo ln -s /usr/bin/nodejs /usr/bin/node
sudo npm install -g yo generator-hubot

mkdir node_modules
ln -s /vagrant hubot
ln -s $(pwd)/node_modules hubot/node_modules

pushd hubot
npm install
popd
