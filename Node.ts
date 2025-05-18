// Core Validator Node Implementation
import { Kafka, Consumer, KafkaMessage } from 'kafkajs';
import { ethers, Contract, Wallet } from 'ethers';
import Redis from 'ioredis';
import { createHash } from 'crypto';
import pino from 'pino';

// Types
interface ProofData {
  blockHash: string;
  blockNumber: number;
  timestamp: number;
  merkleRoot: string;
  transactionHashes: string[];
  stateRoot: string;
  chainId: number;
}

interface ValidatorConfig {
  kafkaConfig: {
    brokers: string[];
    groupId: string;
    topic: string;
  };
  evmConfig: {
    rpcUrl: string;
    privateKey: string;
    contractAddress: string;
    chainId: number;
  };
  redisUrl: string;
  batchSize: number;
  maxBatchWaitMs: number;
  gasSettings: {
    maxFeePerGas: string;
    maxPriorityFeePerGas: string;
    gasLimit: number;
  };
}

// High-performance EVM Validator Node
export class EVMValidatorNode {
  private kafka: Kafka;
  private consumer: Consumer;
  private provider: ethers.JsonRpcProvider;
  private wallet: Wallet;
  private contract: Contract;
  private redis: Redis;
  private logger: pino.Logger;
  private config: ValidatorConfig;
  private proofBatch: ProofData[] = [];
  private batchTimer: NodeJS.Timeout | null = null;
  private isRunning = false;

  // EVM Proof Storage Contract ABI
  private readonly contractABI = [
    "function submitProofBatch(bytes32[] calldata merkleRoots, uint256[] calldata blockNumbers, uint256[] calldata timestamps, uint256[] calldata chainIds) external",
    "function getProof(uint256 blockNumber, uint256 chainId) external view returns (bytes32 merkleRoot, uint256 timestamp, bool exists)",
    "function submitSingleProof(bytes32 merkleRoot, uint256 blockNumber, uint256 timestamp, uint256 chainId) external",
    "function verifyProofExists(uint256 blockNumber, uint256 chainId) external view returns (bool)",
    "event ProofSubmitted(uint256 indexed blockNumber, uint256 indexed chainId, bytes32 merkleRoot, uint256 timestamp)",
    "event BatchProofSubmitted(uint256 count, uint256 timestamp)"
  ];

  constructor(config: ValidatorConfig) {
    this.config = config;
    this.logger = pino({
      name: 'evm-validator',
      level: 'info'
    });

    this.initializeComponents();
  }

  private initializeComponents(): void {
    // Initialize Kafka
    this.kafka = new Kafka({
      clientId: `evm-validator-${Math.random().toString(36).substr(2, 9)}`,
      brokers: this.config.kafkaConfig.brokers,
      retry: {
        initialRetryTime: 100,
        retries: 8
      }
    });

    this.consumer = this.kafka.consumer({
      groupId: this.config.kafkaConfig.groupId,
      sessionTimeout: 30000,
      heartbeatInterval: 3000,
      maxBytesPerPartition: 1048576, // 1MB per partition
      allowAutoTopicCreation: false
    });

    // Initialize EVM components
    this.provider = new ethers.JsonRpcProvider(this.config.evmConfig.rpcUrl);
    this.wallet = new Wallet(this.config.evmConfig.privateKey, this.provider);
    this.contract = new Contract(
      this.config.evmConfig.contractAddress,
      this.contractABI,
      this.wallet
    );

    // Initialize Redis
    this.redis = new Redis(this.config.redisUrl, {
      retryDelayOnFailover: 100,
      maxRetriesPerRequest: 3,
      lazyConnect: true
    });
  }

  async start(): Promise<void> {
    this.logger.info('Starting EVM Validator Node...');
    
    try {
      // Connect to Redis
      await this.redis.connect();
      this.logger.info('Connected to Redis');

      // Connect to Kafka
      await this.consumer.connect();
      await this.consumer.subscribe({ topic: this.config.kafkaConfig.topic });
      this.logger.info(`Subscribed to Kafka topic: ${this.config.kafkaConfig.topic}`);

      // Start consuming messages
      this.isRunning = true;
      await this.consumer.run({
        eachMessage: this.handleKafkaMessage.bind(this),
        partitionsConsumedConcurrently: 3 // Optimize for throughput
      });

      this.logger.info('EVM Validator Node started successfully');
    } catch (error) {
      this.logger.error({ error }, 'Failed to start validator node');
      throw error;
    }
  }

  private async handleKafkaMessage({ message }: { message: KafkaMessage }): Promise<void> {
    try {
      if (!message.value) return;

      const proofData: ProofData = JSON.parse(message.value.toString());
      
      // Validate proof data
      if (!this.validateProofData(proofData)) {
        this.logger.warn({ proofData }, 'Invalid proof data received');
        return;
      }

      // Check if proof already exists (deduplication)
      const exists = await this.checkProofExists(proofData.blockNumber, proofData.chainId);
      if (exists) {
        this.logger.debug({ blockNumber: proofData.blockNumber, chainId: proofData.chainId }, 'Proof already exists, skipping');
        return;
      }

      // Add to batch
      this.proofBatch.push(proofData);
      this.logger.debug({ batchSize: this.proofBatch.length }, 'Added proof to batch');

      // Process batch if full or start timer for partial batch
      if (this.proofBatch.length >= this.config.batchSize) {
        await this.processBatch();
      } else if (this.batchTimer === null) {
        this.batchTimer = setTimeout(() => {
          this.processBatch();
        }, this.config.maxBatchWaitMs);
      }
    } catch (error) {
      this.logger.error({ error, message: message.value?.toString() }, 'Error processing Kafka message');
    }
  }

  private validateProofData(proof: ProofData): boolean {
    return !!(
      proof.blockHash &&
      proof.blockNumber >= 0 &&
      proof.timestamp > 0 &&
      proof.merkleRoot &&
      proof.chainId > 0 &&
      Array.isArray(proof.transactionHashes) &&
      proof.stateRoot
    );
  }

  private async checkProofExists(blockNumber: number, chainId: number): Promise<boolean> {
    try {
      // Check Redis cache first
      const cacheKey = `proof:${chainId}:${blockNumber}`;
      const cached = await this.redis.exists(cacheKey);
      if (cached) return true;

      // Check on-chain
      const exists = await this.contract.verifyProofExists(blockNumber, chainId);
      
      // Cache the result
      if (exists) {
        await this.redis.setex(cacheKey, 3600, '1'); // Cache for 1 hour
      }
      
      return exists;
    } catch (error) {
      this.logger.error({ error, blockNumber, chainId }, 'Error checking proof existence');
      return false; // Assume doesn't exist on error to avoid missing proofs
    }
  }

  private async processBatch(): Promise<void> {
    if (this.proofBatch.length === 0) return;

    const batch = [...this.proofBatch];
    this.proofBatch = [];
    
    if (this.batchTimer) {
      clearTimeout(this.batchTimer);
      this.batchTimer = null;
    }

    try {
      this.logger.info({ batchSize: batch.length }, 'Processing proof batch');

      if (batch.length === 1) {
        await this.submitSingleProof(batch[0]);
      } else {
        await this.submitBatchProofs(batch);
      }

      // Update cache for processed proofs
      await this.cacheProcessedProofs(batch);
      
      this.logger.info({ batchSize: batch.length }, 'Successfully processed proof batch');
    } catch (error) {
      this.logger.error({ error, batchSize: batch.length }, 'Failed to process proof batch');
      
      // Re-add failed proofs to batch for retry (with exponential backoff)
      setTimeout(() => {
        this.proofBatch.unshift(...batch);
      }, 5000);
    }
  }

  private async submitSingleProof(proof: ProofData): Promise<void> {
    const tx = await this.contract.submitSingleProof(
      proof.merkleRoot,
      proof.blockNumber,
      proof.timestamp,
      proof.chainId,
      {
        maxFeePerGas: this.config.gasSettings.maxFeePerGas,
        maxPriorityFeePerGas: this.config.gasSettings.maxPriorityFeePerGas,
        gasLimit: this.config.gasSettings.gasLimit
      }
    );

    const receipt = await tx.wait();
    this.logger.info({
      txHash: receipt.hash,
      blockNumber: proof.blockNumber,
      chainId: proof.chainId,
      gasUsed: receipt.gasUsed?.toString()
    }, 'Single proof submitted successfully');
  }

  private async submitBatchProofs(proofs: ProofData[]): Promise<void> {
    const merkleRoots = proofs.map(p => p.merkleRoot);
    const blockNumbers = proofs.map(p => p.blockNumber);
    const timestamps = proofs.map(p => p.timestamp);
    const chainIds = proofs.map(p => p.chainId);

    const tx = await this.contract.submitProofBatch(
      merkleRoots,
      blockNumbers,
      timestamps,
      chainIds,
      {
        maxFeePerGas: this.config.gasSettings.maxFeePerGas,
        maxPriorityFeePerGas: this.config.gasSettings.maxPriorityFeePerGas,
        gasLimit: this.config.gasSettings.gasLimit * proofs.length
      }
    );

    const receipt = await tx.wait();
    this.logger.info({
      txHash: receipt.hash,
      batchSize: proofs.length,
      gasUsed: receipt.gasUsed?.toString()
    }, 'Batch proofs submitted successfully');
  }

  private async cacheProcessedProofs(proofs: ProofData[]): Promise<void> {
    const pipeline = this.redis.pipeline();
    
    for (const proof of proofs) {
      const cacheKey = `proof:${proof.chainId}:${proof.blockNumber}`;
      pipeline.setex(cacheKey, 3600, '1');
    }
    
    await pipeline.exec();
  }

  async stop(): Promise<void> {
    this.logger.info('Stopping EVM Validator Node...');
    this.isRunning = false;

    if (this.batchTimer) {
      clearTimeout(this.batchTimer);
    }

    // Process any remaining proofs
    if (this.proofBatch.length > 0) {
      await this.processBatch();
    }

    await this.consumer.disconnect();
    await this.redis.disconnect();
    
    this.logger.info('EVM Validator Node stopped');
  }

  // Health check endpoint
  async getHealth(): Promise<{
    status: string;
    components: {
      kafka: boolean;
      evm: boolean;
      redis: boolean;
    };
    stats: {
      pendingProofs: number;
      lastProcessedTime: Date;
    };
  }> {
    try {
      const [kafkaHealth, evmHealth, redisHealth] = await Promise.allSettled([
        this.consumer.describeGroup().then(() => true).catch(() => false),
        this.provider.getBlockNumber().then(() => true).catch(() => false),
        this.redis.ping().then(() => true).catch(() => false)
      ]);

      return {
        status: this.isRunning ? 'running' : 'stopped',
        components: {
          kafka: kafkaHealth.status === 'fulfilled' ? kafkaHealth.value : false,
          evm: evmHealth.status === 'fulfilled' ? evmHealth.value : false,
          redis: redisHealth.status === 'fulfilled' ? redisHealth.value : false
        },
        stats: {
          pendingProofs: this.proofBatch.length,
          lastProcessedTime: new Date()
        }
      };
    } catch (error) {
      this.logger.error({ error }, 'Health check failed');
      throw error;
    }
  }
}

// Validator Node Manager for multiple chains
export class ValidatorNodeManager {
  private validators: Map<number, EVMValidatorNode> = new Map();
  private logger: pino.Logger;

  constructor() {
    this.logger = pino({ name: 'validator-manager' });
  }

  async addValidator(chainId: number, config: ValidatorConfig): Promise<void> {
    if (this.validators.has(chainId)) {
      throw new Error(`Validator for chain ${chainId} already exists`);
    }

    const validator = new EVMValidatorNode(config);
    await validator.start();
    
    this.validators.set(chainId, validator);
    this.logger.info({ chainId }, 'Validator added for chain');
  }

  async removeValidator(chainId: number): Promise<void> {
    const validator = this.validators.get(chainId);
    if (!validator) {
      throw new Error(`No validator found for chain ${chainId}`);
    }

    await validator.stop();
    this.validators.delete(chainId);
    this.logger.info({ chainId }, 'Validator removed for chain');
  }

  async stopAll(): Promise<void> {
    const stopPromises = Array.from(this.validators.values()).map(v => v.stop());
    await Promise.all(stopPromises);
    this.validators.clear();
    this.logger.info('All validators stopped');
  }

  async getHealthStatus(): Promise<Map<number, any>> {
    const healthMap = new Map();
    
    for (const [chainId, validator] of this.validators) {
      try {
        const health = await validator.getHealth();
        healthMap.set(chainId, health);
      } catch (error) {
        healthMap.set(chainId, { status: 'error', error: error.message });
      }
    }
    
    return healthMap;
  }
}

// Usage Example
async function main() {
  const config: ValidatorConfig = {
    kafkaConfig: {
      brokers: ['localhost:9092'],
      groupId: 'evm-validators',
      topic: 'blockchain-proofs'
    },
    evmConfig: {
      rpcUrl: 'https://mainnet.infura.io/v3/YOUR_PROJECT_ID',
      privateKey: 'YOUR_PRIVATE_KEY',
      contractAddress: '0x...', // Will be deployed next
      chainId: 1
    },
    redisUrl: 'redis://localhost:6379',
    batchSize: 50,
    maxBatchWaitMs: 10000,
    gasSettings: {
      maxFeePerGas: ethers.parseUnits('30', 'gwei').toString(),
      maxPriorityFeePerGas: ethers.parseUnits('2', 'gwei').toString(),
      gasLimit: 300000
    }
  };

  const manager = new ValidatorNodeManager();
  
  try {
    // Add validators for multiple chains
    await manager.addValidator(1, { ...config, evmConfig: { ...config.evmConfig, chainId: 1 } }); // Ethereum
    await manager.addValidator(137, { ...config, evmConfig: { ...config.evmConfig, chainId: 137 } }); // Polygon
    await manager.addValidator(42161, { ...config, evmConfig: { ...config.evmConfig, chainId: 42161 } }); // Arbitrum

    // Keep running
    process.on('SIGINT', async () => {
      console.log('Shutting down validators...');
      await manager.stopAll();
      process.exit(0);
    });

    console.log('EVM Validator Nodes started successfully');
  } catch (error) {
    console.error('Failed to start validators:', error);
    process.exit(1);
  }
}

if (require.main === module) {
  main().catch(console.error);
}

export { ValidatorConfig, ProofData };
