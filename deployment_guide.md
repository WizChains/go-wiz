# EVM Validator Node Deployment & Configuration

## Quick Start Guide

### 1. Prerequisites

```bash
# Install dependencies
npm install
# or
yarn install

# Install Redis
docker run -d --name redis -p 6379:6379 redis:alpine

# Install Kafka (Docker Compose)
# docker-compose.yml in project root
```

### 2. Environment Setup

```bash
# Copy environment template
cp .env.example .env

# Edit .env with your configuration
KAFKA_BROKERS=localhost:9092
KAFKA_GROUP_ID=evm-validators-prod
KAFKA_TOPIC=blockchain-proofs

REDIS_URL=redis://localhost:6379

# EVM Configuration (can have multiple)
ETH_RPC_URL=https://mainnet.infura.io/v3/YOUR_PROJECT_ID
ETH_PRIVATE_KEY=0x...
ETH_CONTRACT_ADDRESS=0x...

POLYGON_RPC_URL=https://polygon-mainnet.g.alchemy.com/v2/YOUR_API_KEY
POLYGON_PRIVATE_KEY=0x...
POLYGON_CONTRACT_ADDRESS=0x...

ARBITRUM_RPC_URL=https://arb-mainnet.g.alchemy.com/v2/YOUR_API_KEY
ARBITRUM_PRIVATE_KEY=0x...
ARBITRUM_CONTRACT_ADDRESS=0x...

# Gas Settings
MAX_FEE_PER_GAS=30000000000  # 30 gwei
MAX_PRIORITY_FEE_PER_GAS=2000000000  # 2 gwei
GAS_LIMIT=300000

# Batch Settings
BATCH_SIZE=50
MAX_BATCH_WAIT_MS=10000

# Monitoring
LOG_LEVEL=info
METRICS_PORT=8080
HEALTH_CHECK_PORT=8081
```

### 3. Smart Contract Deployment

```typescript
// deploy.ts
import { ethers } from 'hardhat';

async function deployProofStorage() {
  const [deployer] = await ethers.getSigners();
  
  console.log('Deploying contracts with account:', deployer.address);
  console.log('Account balance:', ethers.formatEther(await deployer.getBalance()), 'ETH');

  // Deploy ProofStorage
  const ProofStorage = await ethers.getContractFactory('ProofStorage');
  const proofStorage = await ProofStorage.deploy(deployer.address);
  await proofStorage.waitForDeployment();
  
  console.log('ProofStorage deployed to:', await proofStorage.getAddress());

  // Deploy ProofVerifier
  const ProofVerifier = await ethers.getContractFactory('ProofVerifier');
  const proofVerifier = await ProofVerifier.deploy(await proofStorage.getAddress());
  await proofVerifier.waitForDeployment();
  
  console.log('ProofVerifier deployed to:', await proofVerifier.getAddress());

  // Deploy ProofQuery
  const ProofQuery = await ethers.getContractFactory('ProofQuery');
  const proofQuery = await ProofQuery.deploy(await proofStorage.getAddress());
  await proofQuery.waitForDeployment();
  
  console.log('ProofQuery deployed to:', await proofQuery.getAddress());

  return {
    proofStorage: await proofStorage.getAddress(),
    proofVerifier: await proofVerifier.getAddress(),
    proofQuery: await proofQuery.getAddress()
  };
}

async function main() {
  try {
    const contracts = await deployProofStorage();
    
    // Save deployment info
    const fs = require('fs');
    const deploymentInfo = {
      network: await ethers.provider.getNetwork(),
      contracts,
      timestamp: new Date().toISOString(),
      deployer: (await ethers.getSigners())[0].address
    };
    
    fs.writeFileSync(
      `deployments/${deploymentInfo.network.name}-${Date.now()}.json`,
      JSON.stringify(deploymentInfo, null, 2)
    );
    
    console.log('Deployment completed successfully!');
  } catch (error) {
    console.error('Deployment failed:', error);
    process.exit(1);
  }
}

if (require.main === module) {
  main().catch(console.error);
}
```

### 4. Validator Configuration

```typescript
// config/validator-config.ts
import { ValidatorConfig } from '../src/validator-node';

export const createValidatorConfig = (chainId: number): ValidatorConfig => {
  const envPrefix = getEnvPrefix(chainId);
  
  return {
    kafkaConfig: {
      brokers: process.env.KAFKA_BROKERS!.split(','),
      groupId: `${process.env.KAFKA_GROUP_ID}-${chainId}`,
      topic: process.env.KAFKA_TOPIC!
    },
    evmConfig: {
      rpcUrl: process.env[`${envPrefix}_RPC_URL`]!,
      privateKey: process.env[`${envPrefix}_PRIVATE_KEY`]!,
      contractAddress: process.env[`${envPrefix}_CONTRACT_ADDRESS`]!,
      chainId
    },
    redisUrl: process.env.REDIS_URL!,
    batchSize: parseInt(process.env.BATCH_SIZE || '50'),
    maxBatchWaitMs: parseInt(process.env.MAX_BATCH_WAIT_MS || '10000'),
    gasSettings: {
      maxFeePerGas: process.env.MAX_FEE_PER_GAS || '30000000000',
      maxPriorityFeePerGas: process.env.MAX_PRIORITY_FEE_PER_GAS || '2000000000',
      gasLimit: parseInt(process.env.GAS_LIMIT || '300000')
    }
  };
};

function getEnvPrefix(chainId: number): string {
  switch (chainId) {
    case 1: return 'ETH';
    case 137: return 'POLYGON';
    case 42161: return 'ARBITRUM';
    case 10: return 'OPTIMISM';
    case 56: return 'BSC';
    default: throw new Error(`Unsupported chain ID: ${chainId}`);
  }
}

// Chain configurations
export const SUPPORTED_CHAINS = [
  { chainId: 1, name: 'Ethereum', rpcUrl: 'https://mainnet.infura.io/v3/' },
  { chainId: 137, name: 'Polygon', rpcUrl: 'https://polygon-mainnet.g.alchemy.com/v2/' },
  { chainId: 42161, name: 'Arbitrum', rpcUrl: 'https://arb-mainnet.g.alchemy.com/v2/' },
  { chainId: 10, name: 'Optimism', rpcUrl: 'https://opt-mainnet.g.alchemy.com/v2/' },
  { chainId: 56, name: 'BSC', rpcUrl: 'https://bsc-dataseed.binance.org/' }
];
```

### 5. Docker Configuration

```dockerfile
# Dockerfile
FROM node:18-alpine

WORKDIR /app

# Install dependencies
COPY package*.json ./
RUN npm ci --only=production

# Copy source code
COPY . .

# Build TypeScript
RUN npm run build

# Create non-root user
RUN addgroup -g 1001 -S nodejs
RUN adduser -S validator -u 1001

# Change ownership
RUN chown -R validator:nodejs /app
USER validator

EXPOSE 8080 8081

CMD ["npm", "start"]
```

```yaml
# docker-compose.yml
version: '3.8'

services:
  zookeeper:
    image: confluentinc/cp-zookeeper:latest
    environment:
      ZOOKEEPER_CLIENT_PORT: 2181
      ZOOKEEPER_TICK_TIME: 2000
    volumes:
      - zookeeper_data:/var/lib/zookeeper/data

  kafka:
    image: confluentinc/cp-kafka:latest
    depends_on:
      - zookeeper
    ports:
      - "9092:9092"
    environment:
      KAFKA_BROKER_ID: 1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://localhost:9092
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_AUTO_CREATE_TOPICS_ENABLE: true
    volumes:
      - kafka_data:/var/lib/kafka/data

  redis:
    image: redis:alpine
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data

  validator-eth:
    build: .
    depends_on:
      - kafka
      - redis
    environment:
      KAFKA_BROKERS: kafka:9092
      REDIS_URL: redis://redis:6379
      CHAIN_IDS: "1"
    volumes:
      - ./config:/app/config
      - ./logs:/app/logs
    restart: unless-stopped

  validator-polygon:
    build: .
    depends_on:
      - kafka
      - redis
    environment:
      KAFKA_BROKERS: kafka:9092
      REDIS_URL: redis://redis:6379
      CHAIN_IDS: "137"
    volumes:
      - ./config:/app/config
      - ./logs:/app/logs
    restart: unless-stopped

  validator-arbitrum:
    build: .
    depends_on:
      - kafka
      - redis
    environment:
      KAFKA_BROKERS: kafka:9092
      REDIS_URL: redis://redis:6379
      CHAIN_IDS: "42161"
    volumes:
      - ./config:/app/config
      - ./logs:/app/logs
    restart: unless-stopped

  prometheus:
    image: prom/prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus

  grafana:
    image: grafana/grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - grafana_data:/var/lib/grafana
      - ./monitoring/grafana/dashboards:/var/lib/grafana/dashboards

volumes:
  zookeeper_data:
  kafka_data:
  redis_data:
  prometheus_data:
  grafana_data:
```

### 6. Monitoring & Health Checks

```typescript
// src/monitoring.ts
import express from 'express';
import prometheus from 'prom-client';
import { ValidatorNodeManager } from './validator-node';

export class MonitoringServer {
  private app = express();
  private manager: ValidatorNodeManager;
  
  // Prometheus metrics
  private proofCounter = new prometheus.Counter({
    name: 'validator_proofs_submitted_total',
    help: 'Total number of proofs submitted',
    labelNames: ['chain_id', 'status']
  });

  private batchSizeHistogram = new prometheus.Histogram({
    name: 'validator_batch_size',
    help: 'Size of proof batches',
    labelNames: ['chain_id'],
    buckets: [1, 5, 10, 25, 50, 100]
  });

  private gasUsedGauge = new prometheus.Gauge({
    name: 'validator_gas_used',
    help: 'Gas used for transactions',
    labelNames: ['chain_id', 'type']
  });

  constructor(manager: ValidatorNodeManager) {
    this.manager = manager;
    this.setupRoutes();
    prometheus.collectDefaultMetrics();
  }

  private setupRoutes() {
    // Health check endpoint
    this.app.get('/health', async (req, res) => {
      try {
        const health = await this.manager.getHealthStatus();
        const overallStatus = Array.from(health.values()).every(h => h.status === 'running');
        
        res.status(overallStatus ? 200 : 500).json({
          status: overallStatus ? 'healthy' : 'unhealthy',
          validators: Object.fromEntries(health)
        });
      } catch (error) {
        res.status(500).json({ status: 'error', error: error.message });
      }
    });

    // Metrics endpoint
    this.app.get('/metrics', (req, res) => {
      res.set('Content-Type', prometheus.register.contentType);
      res.end(prometheus.register.metrics());
    });

    // Ready check
    this.app.get('/ready', (req, res) => {
      res.json({ status: 'ready', timestamp: new Date().toISOString() });
    });

    // Liveness check
    this.app.get('/live', (req, res) => {
      res.json({ status: 'alive', timestamp: new Date().toISOString() });
    });
  }

  start(port: number = 8080) {
    this.app.listen(port, () => {
      console.log(`Monitoring server started on port ${port}`);
    });
  }

  // Metric recording methods
  recordProofSubmitted(chainId: number, status: 'success' | 'failed') {
    this.proofCounter.inc({ chain_id: chainId.toString(), status });
  }

  recordBatchSize(chainId: number, size: number) {
    this.batchSizeHistogram.observe({ chain_id: chainId.toString() }, size);
  }

  recordGasUsed(chainId: number, type: 'single' | 'batch', gasUsed: number) {
    this.gasUsedGauge.set({ chain_id: chainId.toString(), type }, gasUsed);
  }
}
```

### 7. Startup Script

```typescript
// src/main.ts
import { ValidatorNodeManager } from './validator-node';
import { MonitoringServer } from './monitoring';
import { createValidatorConfig, SUPPORTED_CHAINS } from './config/validator-config';
import { setupGracefulShutdown } from './utils/shutdown';

async function main() {
  console.log('Starting EVM Validator Nodes...');
  
  const manager = new ValidatorNodeManager();
  const monitoring = new MonitoringServer(manager);
  
  try {
    // Parse chain IDs from environment or use defaults
    const enabledChains = process.env.CHAIN_IDS 
      ? process.env.CHAIN_IDS.split(',').map(Number)
      : [1, 137, 42161]; // Default: Ethereum, Polygon, Arbitrum

    // Start validators for enabled chains
    for (const chainId of enabledChains) {
      const chainInfo = SUPPORTED_CHAINS.find(chain => chain.chainId === chainId);
      if (!chainInfo) {
        console.warn(`Unsupported chain ID: ${chainId}, skipping...`);
        continue;
      }

      console.log(`Starting validator for ${chainInfo.name} (Chain ID: ${chainId})`);
      const config = createValidatorConfig(chainId);
      await manager.addValidator(chainId, config);
    }

    // Start monitoring server
    monitoring.start(Number(process.env.METRICS_PORT) || 8080);

    // Setup graceful shutdown
    setupGracefulShutdown(async () => {
      console.log('Shutting down validators...');
      await manager.stopAll();
      console.log('Shutdown complete');
    });

    console.log('✅ All validators started successfully!');
    console.log('📊 Monitoring available at http://localhost:8080/health');
    console.log('📈 Metrics available at http://localhost:8080/metrics');

  } catch (error) {
    console.error('❌ Failed to start validators:', error);
    process.exit(1);
  }
}

// Handle unhandled promises
process.on('unhandledRejection', (reason, promise) => {
  console.error('Unhandled Rejection at:', promise, 'reason:', reason);
  process.exit(1);
});

if (require.main === module) {
  main().catch(console.error);
}
```

### 8. Package.json Scripts

```json
{
  "name": "evm-validator-nodes",
  "version": "1.0.0",
  "scripts": {
    "build": "tsc",
    "start": "node dist/main.js",
    "dev": "ts-node src/main.ts",
    "deploy": "hardhat run scripts/deploy.ts",
    "test": "jest",
    "docker:build": "docker build -t evm-validator .",
    "docker:run": "docker-compose up -d",
    "docker:stop": "docker-compose down",
    "logs": "docker-compose logs -f",
    "healthcheck": "curl -f http://localhost:8080/health || exit 1"
  },
  "dependencies": {
    "kafkajs": "^2.2.4",
    "ethers": "^6.8.0",
    "ioredis": "^5.3.2",
    "pino": "^8.15.0",
    "express": "^4.18.2",
    "prom-client": "^14.2.0"
  },
  "devDependencies": {
    "@types/node": "^20.5.0",
    "typescript": "^5.1.6",
    "hardhat": "^2.17.2",
    "@nomicfoundation/hardhat-ethers": "^3.0.4"
  }
}
```

## Next Steps

1. **Deploy Smart Contracts**: Run deployment scripts on target EVM chains
2. **Configure Validators**: Update environment variables with contract addresses
3. **Setup Monitoring**: Deploy Prometheus/Grafana for observability
4. **Start Processing**: Begin consuming Kafka streams and submitting proofs
5. **Scale Horizontally**: Add more validator instances as needed

## Performance Optimizations

- **Batch Processing**: Groups multiple proofs into single transactions
- **Gas Optimization**: Uses packed structs and optimized Solidity patterns
- **Caching**: Redis cache prevents duplicate proof submissions
- **Connection Pooling**: Reuses EVM connections efficiently
- **Graceful Degradation**: Continues processing if individual chains fail

## Security Considerations

- **Role-Based Access**: Only authorized validators can submit proofs
- **Replay Protection**: Prevents duplicate proof submissions
- **Gas Price Management**: Automated gas price adjustment
- **Circuit Breakers**: Pause functionality in case of issues
- **Monitoring**: Comprehensive health checks and metrics