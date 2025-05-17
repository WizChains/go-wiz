Ubuntu — Full Tool Install (Docker + Geth + Bootnode)
1. ⚙️ Update and Upgrade
sudo apt update && sudo apt upgrade -y


2. 🐳 Install Docker Engine
sudo apt install -y ca-certificates curl gnupg lsb-release

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

Post-install (optional but useful):
sudo usermod -aG docker $USER
newgrp docker

3. 🔧 Install Geth + Bootnode

sudo add-apt-repository -y ppa:ethereum/ethereum
sudo apt update
sudo apt install -y ethereum

This gives you:

geth → Ethereum node

bootnode → Enode key generation utility

4. 🧪 Verify Install

geth version
bootnode -h
docker --version
