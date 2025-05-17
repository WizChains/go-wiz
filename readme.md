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




From Zero to Live Permissioned Wiz Node
⚙️ STEP 1 — Setup Project Directory
mkdir wiz && cd wiz
mkdir -p node1/data/geth

🔐 STEP 2 — Generate Node Key (Node Identity)

bootnode -genkey node1/data/geth/nodekey

🛰️ STEP 3 — Get Public Enode (To Share)

bootnode -nodekey node1/data/geth/nodekey -writeaddress
It outputs:
<public_key> (like 4f5b7b...)

Now build the enode URL (replace YOUR_IP):

echo "enode://<public_key>@YOUR_IP:30303" > node1/enode.txt


🧾 STEP 4 — Create genesis.json

cat <<EOF > genesis.json
{
  "config": {
    "chainId": 777,
    "homesteadBlock": 0,
    "eip150Block": 0,
    "eip155Block": 0,
    "eip158Block": 0
  },
  "difficulty": "0x1",
  "gasLimit": "0x8000000",
  "alloc": {
    "0x0000000000000000000000000000000000000001": {
      "balance": "100000000000000000000000"
    }
  }
}
EOF

🧱 STEP 5 — Initialize the Chain from Genesis

geth --datadir node1/data init genesis.json

📡 STEP 6 — Create static-nodes.json with Whitelisted Peers
If you only have one node for now (self-peering):


cat <<EOF > node1/data/static-nodes.json
[
  "enode://<public_key>@YOUR_IP:30303"
]
EOF

Later you’ll add more enode URLs from other nodes to this list.

🧑‍💻 STEP 7 — Create an Ethereum Account (Optional)

geth --datadir node1/data account new
Copy the address if you want to pre-allocate balance in genesis.json.

🚀 STEP 8 — Start the Node

geth --datadir node1/data \
     --networkid 1337 \
     --nodiscover \
     --http \
     --http.addr 0.0.0.0 \
     --http.port 8545 \
     --http.api web3,eth,net,personal \
     --port 30303 \
     --verbosity 3 \
     console
This will start your custom Ethereum chain with permissioned peering.

🧪 TO ADD MORE NODES
Repeat for each new node:

Generate nodekey

Get enode using bootnode -writeaddress

Share with peers and update everyone's static-nodes.json

Run geth init genesis.json

Launch with --nodiscover etc.

