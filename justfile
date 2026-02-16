set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Deploy a brand-new superchain + OPCM + chain, start compose, deploy bridge, and write scripts/.env.runtime.
deploy:
    ./devnet/scripts/deploy-new-superchain-and-chain.sh

# Deposit test amount in token units (default: 1 token).
deposit-test amount="1":
    ./devnet/scripts/deposit-test.sh {{amount}}

# Withdrawal test amount in token units (default: 1 token).
# Optional `resume_hash` lets you continue an in-flight withdrawal.
withdraw-test amount="1" resume_hash="":
    ./devnet/scripts/withdraw-test.sh {{amount}} {{resume_hash}}
