echo "deb [trusted=yes]    https://deb.nodesource.com/node xenial main" | sudo tee /etc/apt/sources.list.d/node.js.list > /dev/null
sudo apt-get update
sudo apt-get install -y nodejs npm
# Needed for hipchat
sudo apt-get install -y libexpat1-dev
sudo ln -snf /usr/bin/nodejs /usr/bin/node
sudo npm install -g yo generator-hubot

ln -snf hubot/package.json .
npm install
ln -snf ../node_modules hubot/
