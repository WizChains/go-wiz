sudo apt install -y golang
sudo apt install make  
git clone https://github.com/ethereum/go-ethereum.git
cd go-ethereum
make all


📁 1. Setup Directories

mkdir -p ~/wiz/node1/data/geth
cd ~/wiz

🔐 2. Generate a Node Key (32-byte hex)

openssl rand -hex 32 > node1/data/geth/nodekey
🌐 3. Derive the Enode URL

cd ~/wiz/go-ethereum
NODEKEY=$(cat ~/wiz/node1/data/geth/nodekey)
./build/bin/devp2p nodeid -nodekeyhex $NODEKEY
📌 Output:


enode://<public_key>
Now build the full enode URL (example IP used):


echo "enode://<public_key>@YOUR.SERVER.IP:30303" > ~/wiz/node1/enode.txt
🧾 4. Create genesis.json

cd ~/wiz

cat <<EOF > genesis.json
{
  "config": {
    "chainId": 1337,
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
🧱 5. Initialize the Chain

~/wiz/go-ethereum/build/bin/geth --datadir node1/data init genesis.json
🔗 6. Create Static Peering File
bash
Copy
Edit
cat <<EOF > node1/data/static-nodes.json
[
  "enode://<public_key>@YOUR.SERVER.IP:30303"
]
EOF
Add more enodes from peers here later if needed.

🔑 7. (Optional) Create a Funded Account

~/wiz/go-ethereum/build/bin/geth --datadir node1/data account new
Copy the account address to your genesis.json if needed for faucet/funding.

🚀 8. Start the Node (Static-Peer Mode)

~/wiz/go-ethereum/build/bin/geth --datadir node1/data \
     --networkid 1337 \
     --nodiscover \
     --http \
     --http.addr 0.0.0.0 \
     --http.port 8545 \
     --http.api web3,eth,net,personal \
     --port 30303 \
     --verbosity 3 \
     console
