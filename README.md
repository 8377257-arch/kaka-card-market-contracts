# KAKA CARD MARKET contracts

This repository contains the public Solidity source and reproducible local tests for the KAKA CARD MARKET contracts deployed on BNB Smart Chain. It deliberately contains no private keys, seed phrases, RPC credentials, unpublished reveal material, encrypted review evidence, or operational infrastructure configuration.

## Mainnet deployment

| Contract | Address |
| --- | --- |
| Collection manager | [`0xe4cdE81575989d7E688Ce49529dc180A6e43AF50`](https://bscscan.com/address/0xe4cdE81575989d7E688Ce49529dc180A6e43AF50#code) |
| Cards | [`0x56C8Aee9693A8ee3a3CDC4d36f9579e555Cd6b51`](https://bscscan.com/address/0x56C8Aee9693A8ee3a3CDC4d36f9579e555Cd6b51#code) |
| Packs | [`0x1Bc49B07bC22bFe9fb1e7660751196ED569B19D6`](https://bscscan.com/address/0x1Bc49B07bC22bFe9fb1e7660751196ED569B19D6#code) |
| Marketplace | [`0xbB18DaD0B1c08A316d325475E9AF2178122957eB`](https://bscscan.com/address/0xbB18DaD0B1c08A316d325475E9AF2178122957eB#code) |

- Chain ID: `56`
- Deployment transaction: [`0x437a34d9388335b763c33c901688b6560c2d250c8a7e1c79820e9510ca18cdda`](https://bscscan.com/tx/0x437a34d9388335b763c33c901688b6560c2d250c8a7e1c79820e9510ca18cdda)
- Deployment block: `124096835`
- Candidate: `kaka-public-scale-c9481ccdffc2ddf8`
- Compiler: Solidity `0.8.37`, optimizer enabled with `500` runs, EVM `paris`
- Manager creation-code hash: `0x06dfc544c7416f85617a89141e011f76c3a2ec8f2043e52f91bda3c854a5831d`

All four contracts have exact runtime matches in [Sourcify](https://repo.sourcify.dev/56/0xe4cdE81575989d7E688Ce49529dc180A6e43AF50). The machine-readable deployment and verification records are in [`deployments/`](deployments/).

## Review scope

The system implements fixed integer card supply, committed pack contents, three issuance modes, delayed pack reveal, unique ERC-721 card instances, signed two-step burns, emergency pause controls, role separation, marketplace escrow, and 5% platform fees on primary and secondary transactions.

Useful review targets include:

- supply conservation and unique card-instance identifiers;
- commitment and reveal correctness, deadlines, incident recovery, and publisher availability assumptions;
- publisher, reviewer, risk, and governance role boundaries;
- pack locks, marketplace escrow, cancellation, proceeds, reentrancy, and denial-of-service paths;
- signed burn intent replay protection, deadlines, ownership checks, and batch behavior;
- monotonic expansion of publisher and collection limits.

This publication is evidence for public review. It is not a claim that an independent security audit has been completed.

## Reproduce locally

```bash
npm install
npm run compile
npm test
```

The Hardhat configuration has no live-network entry and does not read deployment keys or RPC secrets.

## License

MIT. See [LICENSE](LICENSE).
