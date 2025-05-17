#!/bin/bash

# =========================================
# ✅ Ethereum PoS Devnet Setup - Updated with Lodestar CLI 2025
# =========================================

# 1. Install dependencies
sudo apt update && sudo apt install -y \
  build-essential git curl wget jq make unzip \
  golang nodejs npm openssl xxd

# 2. Build and install Geth
cd ~
git clone https://github.com/ethereum/go-ethereum.git
cd go-ethereum
make geth
sudo cp build/bin/geth /usr/local/bin/

# 3. Install Lodestar
npm install -g @chainsafe/lodestar

# 4. Build eth-beacon-genesis
cd ~
git clone https://github.com/ethpandaops/eth-beacon-genesis.git
cd eth-beacon-genesis
go build ./cmd/eth-beacon-genesis
sudo cp eth-beacon-genesis /usr/local/bin/

# 5. Prepare working directory
mkdir -p /root/wiz && cd /root/wiz

# 6. Create genesis.json
cat > genesis.json <<EOF
{
  "config": {
    "chainId": 1337,
    "homesteadBlock": 0,
    "eip150Block": 0,
    "eip155Block": 0,
    "eip158Block": 0,
    "byzantiumBlock": 0,
    "constantinopleBlock": 0,
    "petersburgBlock": 0,
    "istanbulBlock": 0,
    "muirGlacierBlock": 0,
    "berlinBlock": 0,
    "londonBlock": 0,
    "shanghaiTime": 0,
    "cancunTime": 0,
    "terminalTotalDifficulty": 0,
    "terminalTotalDifficultyPassed": true,
    "blobSchedule": {
      "cancun": {
        "target": 3,
        "max": 6,
        "baseFeeUpdateFraction": 3338477
      }
    }
  },
  "nonce": "0x0",
  "timestamp": "0x0",
  "extraData": "0x",
  "gasLimit": "0x1c9c380",
  "difficulty": "0x0",
  "baseFeePerGas": "0x7",
  "mixHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "coinbase": "0x0000000000000000000000000000000000000000",
  "alloc": {}
}
EOF


# 7. Create config.yaml for consensus layer
cat > config.yaml <<EOF
PRESET_BASE: "minimal"
CONFIG_NAME: "devnet"
MIN_GENESIS_ACTIVE_VALIDATOR_COUNT: 4
MIN_GENESIS_TIME: 1607428800
GENESIS_FORK_VERSION: 0x00000000
GENESIS_DELAY: 30
ALTAIR_FORK_VERSION: 0x01000000
ALTAIR_FORK_EPOCH: 0
BELLATRIX_FORK_VERSION: 0x02000000
BELLATRIX_FORK_EPOCH: 0
CAPELLA_FORK_VERSION: 0x03000000
CAPELLA_FORK_EPOCH: 0
DENEB_FORK_VERSION: 0x04000000
DENEB_FORK_EPOCH: 0
ELECTRA_FORK_VERSION: 0x05000000
ELECTRA_FORK_EPOCH: 0
EOF

# 8. Create mnemonics.yaml
cat > mnemonics.yaml <<EOF
- mnemonic: "test test test test test test test test test test test junk"
  start: 0
  count: 4
  balance: 32000000000
  wd_address: "0x000000000000000000000000000000000000dead"
  wd_prefix: "0x01"
EOF

# 9. Create jwt.hex
openssl rand -hex 32 | tr -d "\n" > /root/wiz/jwt.hex
chmod 600 /root/wiz/jwt.hex

# 10. Generate genesis state
eth-beacon-genesis devnet \
  --eth1-config /root/wiz/genesis.json \
  --config /root/wiz/config.yaml \
  --mnemonics /root/wiz/mnemonics.yaml \
  --state-output /root/wiz/genesis.ssz \
  --json-output /root/wiz/genesis-cl.json

# 11. Initialize Geth
mkdir -p /root/wiz/node1/el-data
geth --datadir /root/wiz/node1/el-data init /root/wiz/genesis.json

# 12. Start Geth
geth --datadir /root/wiz/node1/el-data \
  --networkid 1337 \
  --authrpc.jwtsecret /root/wiz/jwt.hex \
  --authrpc.port 8551 \
  --authrpc.addr 0.0.0.0 \
  --authrpc.vhosts=* \
  --http --http.addr 0.0.0.0 --http.port 8545 \
  --http.api engine,eth,web3,net \
  --port 30303 \
  --nodiscover \
  --verbosity 3

# 13. Start Lodestar Beacon Node
lodestar beacon \
  --dataDir /root/wiz/node1/cl-data \
  --network=dev \
  --paramsFile /root/wiz/config.yaml \
  --genesisStateFile /root/wiz/genesis.ssz \
  --execution.urls=http://localhost:8551 \
  --jwtSecret=/root/wiz/jwt.hex \
  --persistNetworkIdentity=false \
  --rest.address=0.0.0.0 \
  --logLevel=info

# 14. Start Lodestar Validator
lodestar validator \
  --dataDir /root/wiz/node1/vc-data \
  --network=dev \
  --paramsFile /root/wiz/config.yaml \
  --mnemonic "test test test test test test test test test test test junk" \
  --numValidators 4 \
  --beaconNodes=http://localhost:9596

