set shell := ["env", "PS1=>", "bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Deploy a brand-new superchain + OPCM + chain and start compose services.
deploy-chain:
    if [ ! -f lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol ] || [ ! -f lib/optimism/op-deployer/README.md ]; then \
      git submodule update --init --recursive; \
    fi
    if [ ! -d tasks/node_modules ]; then \
      if [ -f tasks/package-lock.json ]; then \
        (cd tasks && npm ci --no-audit --no-fund); \
      else \
        (cd tasks && npm install --no-audit --no-fund); \
      fi; \
    fi
    cd tasks && npx tsx deploy.ts chain

# Deploy CGT bridge contracts + runtime wiring on the latest deployed chain.
deploy-bridge:
    if [ ! -f lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol ] || [ ! -f lib/optimism/op-deployer/README.md ]; then \
      git submodule update --init --recursive; \
    fi
    if [ ! -d tasks/node_modules ]; then \
      if [ -f tasks/package-lock.json ]; then \
        (cd tasks && npm ci --no-audit --no-fund); \
      else \
        (cd tasks && npm install --no-audit --no-fund); \
      fi; \
    fi
    cd tasks && npx tsx deploy.ts bridge

# Deposit test amount in token units (default: 1 token).
deposit-test amount="1":
    ./devnet/scripts/deposit-test.sh {{amount}}

# Withdrawal test amount in token units (default: 1 token).
# Optional `resume_hash` lets you continue an in-flight withdrawal.
withdraw-test amount="1" resume_hash="":
    ./devnet/scripts/withdraw-test.sh {{amount}} {{resume_hash}}
